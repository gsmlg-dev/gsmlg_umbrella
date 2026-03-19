defmodule GSMLG.Storage.ContentType do
  @moduledoc """
  Detects content type from file data using magic bytes.
  Never trusts client-provided MIME types.
  """

  @doc """
  Detects content type from binary data using magic byte signatures.
  Returns `{:ok, mime_type}`. Falls back to `"application/octet-stream"` for unknown types.
  """
  def detect(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg"}

  def detect(<<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>),
    do: {:ok, "image/png"}

  def detect(<<"GIF87a", _::binary>>), do: {:ok, "image/gif"}
  def detect(<<"GIF89a", _::binary>>), do: {:ok, "image/gif"}
  def detect(<<"RIFF", _size::32, "WEBP", _::binary>>), do: {:ok, "image/webp"}
  def detect(<<0x25, 0x50, 0x44, 0x46, _::binary>>), do: {:ok, "application/pdf"}
  def detect(<<0x50, 0x4B, 0x03, 0x04, _::binary>>), do: {:ok, "application/zip"}
  def detect(<<0x1F, 0x8B, _::binary>>), do: {:ok, "application/gzip"}

  # SVG detection (XML-based)
  def detect(data) when is_binary(data) do
    trimmed = String.trim_leading(data)

    cond do
      String.starts_with?(trimmed, "<?xml") and String.contains?(trimmed, "<svg") ->
        {:ok, "image/svg+xml"}

      String.starts_with?(trimmed, "<svg") ->
        {:ok, "image/svg+xml"}

      String.starts_with?(trimmed, "<!DOCTYPE html") or String.starts_with?(trimmed, "<html") ->
        {:ok, "text/html"}

      # BMP
      match?(<<0x42, 0x4D, _::binary>>, data) ->
        {:ok, "image/bmp"}

      # TIFF (little-endian)
      match?(<<0x49, 0x49, 0x2A, 0x00, _::binary>>, data) ->
        {:ok, "image/tiff"}

      # TIFF (big-endian)
      match?(<<0x4D, 0x4D, 0x00, 0x2A, _::binary>>, data) ->
        {:ok, "image/tiff"}

      # MP4 / MOV (ftyp box)
      match?(<<_::32, "ftyp", _::binary>>, data) ->
        {:ok, "video/mp4"}

      # Default to octet-stream for unknown types
      true ->
        {:ok, "application/octet-stream"}
    end
  end

  @doc """
  Returns true if the content type is an image type.
  """
  def image?("image/" <> _), do: true
  def image?(_), do: false
end
