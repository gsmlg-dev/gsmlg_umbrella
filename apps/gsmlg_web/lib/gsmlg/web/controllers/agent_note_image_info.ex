defmodule GSMLG.Web.AgentNoteImageInfo do
  @moduledoc """
  Bounded image header validation for PDF export, without decoding image pixels.

  Checks PNG IHDR, GIF logical screen, JPEG SOF and WebP frame/canvas headers.
  JPEG metadata scanning is limited to 64 KiB and 256 segments. This does not
  validate compressed pixels, later frames/chunks, or full decoder compatibility.
  """
  import Bitwise

  @max_pixels 20_000_000
  @jpeg_scan_bytes 65_536
  @jpeg_segments 256
  @sof_markers [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF]
  @segment_markers @sof_markers ++
                     [0xC4, 0xCC, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF, 0xFE] ++ Enum.to_list(0xE0..0xEF)

  @spec dimensions(term(), term()) ::
          {:ok, {pos_integer(), pos_integer()}} | {:error, :invalid | :pixel_limit}
  def dimensions(mime, bytes) when is_binary(mime) and is_binary(bytes) do
    if String.valid?(mime) do
      type = mime |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()

      case header(type, bytes) do
        {:ok, {width, height}} when width > 0 and height > 0 ->
          if width * height <= @max_pixels,
            do: {:ok, {width, height}},
            else: {:error, :pixel_limit}

        _ ->
          {:error, :invalid}
      end
    else
      {:error, :invalid}
    end
  end

  def dimensions(_, _), do: {:error, :invalid}

  defp header(
         "image/png",
         <<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", width::32, height::32, depth, color,
           0, 0, interlace, crc::32, _::binary>>
       )
       when interlace in [0, 1] do
    allowed_depths =
      case color do
        0 -> [1, 2, 4, 8, 16]
        2 -> [8, 16]
        3 -> [1, 2, 4, 8]
        c when c in [4, 6] -> [8, 16]
        _ -> []
      end

    ihdr = <<"IHDR", width::32, height::32, depth, color, 0, 0, interlace>>

    if depth in allowed_depths and :erlang.crc32(ihdr) == crc,
      do: {:ok, {width, height}},
      else: {:error, :invalid}
  end

  defp header(
         "image/gif",
         <<version::binary-size(6), width::little-16, height::little-16, _::binary-size(3),
           _::binary>>
       )
       when version in ["GIF87a", "GIF89a"],
       do: {:ok, {width, height}}

  defp header(mime, <<0xFF, 0xD8, bytes::binary>>) when mime in ["image/jpeg", "image/jpg"] do
    jpeg(binary_part(bytes, 0, min(byte_size(bytes), @jpeg_scan_bytes)), @jpeg_segments)
  end

  defp header("image/webp", <<"RIFF", size::little-32, "WEBP", chunks::binary>>)
       when size == byte_size(chunks) + 4 do
    case chunks do
      <<kind::binary-size(4), length::little-32, rest::binary>>
      when length + rem(length, 2) <= byte_size(rest) ->
        webp(kind, binary_part(rest, 0, length))

      _ ->
        {:error, :invalid}
    end
  end

  defp header(_, _), do: {:error, :invalid}

  defp jpeg(<<0xFF, 0xFF, rest::binary>>, remaining) when remaining > 0,
    do: jpeg(<<0xFF, rest::binary>>, remaining - 1)

  defp jpeg(<<0xFF, marker, length::16, rest::binary>>, remaining)
       when remaining > 0 and length >= 2 and length - 2 <= byte_size(rest) and
              marker in @segment_markers do
    size = length - 2
    <<segment::binary-size(size), tail::binary>> = rest

    if marker in @sof_markers do
      case segment do
        <<precision, height::16, width::16, components, descriptors::binary>>
        when components in 1..4 and
               byte_size(descriptors) == components * 3 ->
          if valid_precision?(marker, precision) and valid_components?(descriptors),
            do: {:ok, {width, height}},
            else: {:error, :invalid}

        _ ->
          {:error, :invalid}
      end
    else
      jpeg(tail, remaining - 1)
    end
  end

  defp jpeg(_, _), do: {:error, :invalid}

  defp valid_precision?(0xC0, precision), do: precision == 8

  defp valid_precision?(marker, precision) when marker in [0xC3, 0xC7, 0xCB, 0xCF],
    do: precision in 2..16

  defp valid_precision?(_, precision), do: precision in [8, 12]

  defp valid_components?(descriptors) do
    components = for <<id, sampling, table <- descriptors>>, do: {id, sampling, table}

    Enum.uniq_by(components, &elem(&1, 0)) == components and
      Enum.all?(components, fn {_, sampling, table} ->
        bsr(sampling, 4) in 1..4 and band(sampling, 15) in 1..4 and table <= 3
      end)
  end

  defp webp(
         "VP8 ",
         <<tag::little-24, 0x9D, 0x01, 0x2A, width::little-16, height::little-16, _::binary>>
       )
       when band(tag, 1) == 0 and band(bsr(tag, 1), 7) <= 3,
       do: {:ok, {band(width, 0x3FFF), band(height, 0x3FFF)}}

  defp webp("VP8L", <<0x2F, bits::little-32, _::binary>>) when bsr(bits, 29) == 0,
    do: {:ok, {band(bits, 0x3FFF) + 1, band(bsr(bits, 14), 0x3FFF) + 1}}

  defp webp("VP8X", <<flags, 0, 0, 0, width::little-24, height::little-24>>)
       when band(flags, 0xC1) == 0,
       do: {:ok, {width + 1, height + 1}}

  defp webp(_, _), do: {:error, :invalid}
end
