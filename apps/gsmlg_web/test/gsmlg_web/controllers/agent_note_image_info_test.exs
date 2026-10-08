defmodule GSMLG.Web.AgentNoteImageInfoTest do
  use ExUnit.Case, async: true
  alias GSMLG.Web.AgentNoteImageInfo

  test "PNG signature and complete IHDR yield dimensions" do
    image = Base.decode64!("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ")
    assert {:ok, {1, 1}} = AgentNoteImageInfo.dimensions("image/png", image)

    assert {:ok, {640, 480}} =
             AgentNoteImageInfo.dimensions("IMAGE/PNG; charset=binary", png(640, 480))
  end

  test "GIF87a and GIF89a logical screen headers yield dimensions" do
    for version <- ["GIF87a", "GIF89a"] do
      assert {:ok, {320, 200}} =
               AgentNoteImageInfo.dimensions(
                 "image/gif",
                 <<version::binary, 320::little-16, 200::little-16, 0, 0, 0>>
               )
    end
  end

  test "JPEG walks complete metadata segments to baseline and progressive SOF" do
    for marker <- [0xC0, 0xC2] do
      image =
        <<0xFF, 0xD8, 0xFF, 0xE0, 0, 6, "JFIF", 0xFF, 0xFF, marker, 0, 11, 8, 480::16, 640::16, 1,
          1, 0x11, 0>>

      assert {:ok, {640, 480}} = AgentNoteImageInfo.dimensions("image/jpeg", image)
      assert {:ok, {640, 480}} = AgentNoteImageInfo.dimensions("image/jpg", image)
    end
  end

  test "WebP lossy lossless and extended headers yield dimensions" do
    assert {:ok, {640, 480}} =
             AgentNoteImageInfo.dimensions(
               "image/webp",
               webp("VP8 ", <<0x10, 0, 0, 0x9D, 0x01, 0x2A, 640::little-16, 480::little-16>>)
             )

    assert {:ok, {2, 3}} =
             AgentNoteImageInfo.dimensions("image/webp", webp("VP8L", <<0x2F, 0x01, 0x80, 0, 0>>))

    assert {:ok, {640, 480}} =
             AgentNoteImageInfo.dimensions(
               "image/webp",
               webp("VP8X", <<0, 0, 0, 0, 639::little-24, 479::little-24>>)
             )
  end

  test "every proper prefix of a supported header is rejected" do
    images = [
      {"image/png", png(1, 1)},
      {"image/gif", <<"GIF89a", 1::little-16, 1::little-16, 0, 0, 0>>},
      {"image/jpeg", <<0xFF, 0xD8, 0xFF, 0xC0, 0, 11, 8, 1::16, 1::16, 1, 1, 0x11, 0>>},
      {"image/webp", webp("VP8L", <<0x2F, 0x01, 0x80, 0, 0>>)}
    ]

    for {mime, image} <- images, size <- 0..(byte_size(image) - 1) do
      assert {:error, :invalid} = AgentNoteImageInfo.dimensions(mime, binary_part(image, 0, size))
    end
  end

  test "MIME mismatch unsupported MIME and nonbinary input are rejected" do
    for mime <- ["image/jpeg", "image/gif", "image/webp", "image/svg+xml", "text/plain", nil] do
      assert {:error, :invalid} = AgentNoteImageInfo.dimensions(mime, png(1, 1))
    end

    assert {:error, :invalid} = AgentNoteImageInfo.dimensions("image/png", nil)
  end

  test "invalid PNG IHDR length checksum and color depth are rejected" do
    <<signature::binary-size(8), _length::32, rest::binary>> = png(1, 1)

    assert {:error, :invalid} =
             AgentNoteImageInfo.dimensions(
               "image/png",
               <<signature::binary, 12::32, rest::binary>>
             )

    <<prefix::binary-size(32), byte>> = png(1, 1)

    assert {:error, :invalid} =
             AgentNoteImageInfo.dimensions("image/png", <<prefix::binary, Bitwise.bxor(byte, 1)>>)

    assert {:error, :invalid} = AgentNoteImageInfo.dimensions("image/png", png(1, 1, 3))
  end

  test "JPEG rejects bad segment lengths missing SOF and incomplete components" do
    for bytes <- [
          <<0xFF, 0xD8, 0xFF, 0xE0, 0, 1>>,
          <<0xFF, 0xD8, 0xFF, 0xDA>>,
          <<0xFF, 0xD8, 0xFF, 0xC0, 0, 8, 8, 1::16, 1::16, 1>>
        ] do
      assert {:error, :invalid} = AgentNoteImageInfo.dimensions("image/jpeg", bytes)
    end
  end

  test "WebP rejects invalid RIFF size signatures and reserved version bits" do
    for image <- [
          webp("VP8 ", <<0x10, 0, 0, "wrong!", 0>>),
          webp("VP8L", <<0x2F, 0, 0, 0, 0xE0>>),
          webp("VP8X", <<0xC1, 0, 0, 0, 0::48>>),
          <<"RIFF", 0::little-32, "WEBP">>
        ] do
      assert {:error, :invalid} = AgentNoteImageInfo.dimensions("image/webp", image)
    end
  end

  test "zero dimensions reject and 20 million pixels is inclusive" do
    assert {:error, :invalid} = AgentNoteImageInfo.dimensions("image/png", png(0, 10))

    assert {:error, :invalid} =
             AgentNoteImageInfo.dimensions(
               "image/gif",
               <<"GIF89a", 1::little-16, 0::little-16, 0, 0, 0>>
             )

    assert {:ok, {5000, 4000}} = AgentNoteImageInfo.dimensions("image/png", png(5000, 4000))
    assert {:error, :pixel_limit} = AgentNoteImageInfo.dimensions("image/png", png(5001, 4000))

    assert {:error, :pixel_limit} =
             AgentNoteImageInfo.dimensions(
               "image/webp",
               webp("VP8X", <<0::32, 0xFFFFFF::little-24, 0xFFFFFF::little-24>>)
             )
  end

  test "JPEG metadata scanning has bounded work" do
    bytes = <<0xFF, 0xD8>> <> :binary.copy(<<0xFF, 0xE0, 0, 2>>, 100_000)
    assert {:error, :invalid} = AgentNoteImageInfo.dimensions("image/jpeg", bytes)
  end

  test "JPEG rejects reserved markers invalid baseline precision and sampling factors" do
    for {marker, precision, sampling} <- [{0x02, 8, 0x11}, {0xC0, 12, 0x11}, {0xC0, 8, 0}] do
      bytes = <<0xFF, 0xD8, 0xFF, marker, 0, 11, precision, 1::16, 1::16, 1, 1, sampling, 0>>
      assert {:error, :invalid} = AgentNoteImageInfo.dimensions("image/jpeg", bytes)
    end
  end

  defp png(width, height, depth \\ 8) do
    header = <<"IHDR", width::32, height::32, depth, 6, 0, 0, 0>>
    <<137, 80, 78, 71, 13, 10, 26, 10, 13::32, header::binary, :erlang.crc32(header)::32>>
  end

  defp webp(kind, payload) do
    padding = if rem(byte_size(payload), 2) == 1, do: <<0>>, else: <<>>

    body =
      <<"WEBP", kind::binary, byte_size(payload)::little-32, payload::binary, padding::binary>>

    <<"RIFF", byte_size(body)::little-32, body::binary>>
  end
end
