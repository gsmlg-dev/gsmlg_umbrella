defmodule GSMLG.Storage.ContentType do
  @moduledoc """
  Detects content type from file data and constrained filename hints.
  Never trusts client-provided MIME types.
  """

  @detect_head_size 4096

  @text_extension_types %{
    ".txt" => "text/plain",
    ".md" => "text/markdown",
    ".markdown" => "text/markdown",
    ".json" => "application/json",
    ".csv" => "text/csv",
    ".xml" => "text/xml"
  }

  @doc """
  Detects content type from binary data without filename context.
  Returns `{:ok, mime_type}`. Falls back to `"application/octet-stream"` for unknown types.
  """
  def detect(data) when is_binary(data), do: detect(data, nil)

  @doc """
  Detects content type from binary data, using the filename only after content checks
  establish that unmatched data is safe text.
  """
  def detect(data, filename)
      when is_binary(data) and (is_binary(filename) or is_nil(filename)) do
    case magic_type(data) do
      nil -> detect_without_magic(data, filename)
      content_type -> {:ok, content_type}
    end
  end

  defp magic_type(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"

  defp magic_type(<<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>),
    do: "image/png"

  defp magic_type(<<"GIF87a", _::binary>>), do: "image/gif"
  defp magic_type(<<"GIF89a", _::binary>>), do: "image/gif"
  defp magic_type(<<"RIFF", _size::32, "WEBP", _::binary>>), do: "image/webp"
  defp magic_type(<<0x25, 0x50, 0x44, 0x46, _::binary>>), do: "application/pdf"
  defp magic_type(<<0x50, 0x4B, 0x03, 0x04, _::binary>>), do: "application/zip"
  defp magic_type(<<0x1F, 0x8B, _::binary>>), do: "application/gzip"
  defp magic_type(<<0x42, 0x4D, _::binary>>), do: "image/bmp"
  defp magic_type(<<0x49, 0x49, 0x2A, 0x00, _::binary>>), do: "image/tiff"
  defp magic_type(<<0x4D, 0x4D, 0x00, 0x2A, _::binary>>), do: "image/tiff"
  defp magic_type(<<_::32, "ftyp", _::binary>>), do: "video/mp4"
  defp magic_type(_data), do: nil

  # SVG and text-based detection — only inspect the first 4KB to avoid
  # scanning large binaries and to prevent deep-embedded <svg> from
  # being misclassified (SVG can contain JavaScript = XSS vector).
  defp detect_without_magic(data, filename) do
    if safe_text?(data) do
      case active_text_type(data) do
        nil ->
          {:ok, text_type_for_filename(filename)}

        content_type ->
          {:ok, content_type}
      end
    else
      {:ok, "application/octet-stream"}
    end
  end

  defp active_text_type(data) do
    head = binary_part(data, 0, min(byte_size(data), @detect_head_size))
    trimmed = trim_leading_ascii_whitespace(head)

    cond do
      starts_with?(trimmed, "<?xml") and contains?(trimmed, "<svg") ->
        "image/svg+xml"

      starts_with?(trimmed, "<svg") ->
        "image/svg+xml"

      starts_with?(trimmed, "<!DOCTYPE html") or starts_with?(trimmed, "<html") ->
        "text/html"

      true ->
        nil
    end
  end

  defp safe_text?(data) do
    String.valid?(data) and
      :binary.match(data, <<0>>) == :nomatch and
      allowed_text_codepoints?(data)
  end

  defp allowed_text_codepoints?(<<>>), do: true

  defp allowed_text_codepoints?(<<codepoint::utf8, rest::binary>>)
       when codepoint in [0x09, 0x0A, 0x0D],
       do: allowed_text_codepoints?(rest)

  defp allowed_text_codepoints?(<<codepoint::utf8, _rest::binary>>)
       when codepoint < 0x20 or codepoint in 0x7F..0x9F,
       do: false

  defp allowed_text_codepoints?(<<_codepoint::utf8, rest::binary>>),
    do: allowed_text_codepoints?(rest)

  defp text_type_for_filename(filename) do
    extension =
      if is_binary(filename) and String.valid?(filename) do
        filename
        |> Path.extname()
        |> String.downcase()
      else
        ""
      end

    Map.get(@text_extension_types, extension, "text/plain")
  end

  defp trim_leading_ascii_whitespace(<<character, rest::binary>>)
       when character in [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20] do
    trim_leading_ascii_whitespace(rest)
  end

  defp trim_leading_ascii_whitespace(data), do: data

  defp starts_with?(data, prefix) do
    prefix_size = byte_size(prefix)

    byte_size(data) >= prefix_size and
      binary_part(data, 0, prefix_size) == prefix
  end

  defp contains?(data, pattern) do
    case :binary.match(data, pattern) do
      :nomatch -> false
      {_position, _length} -> true
    end
  end

  @doc """
  Returns true if the content type is an image type.
  """
  def image?("image/" <> _), do: true
  def image?(_), do: false
end
