defmodule GSMLG.Storage.ImageProcessor do
  @moduledoc """
  Image processing using Vix/libvips for memory-efficient variant generation.

  Falls back gracefully if Vix is not available — variants simply won't be generated.
  """

  require Logger

  @doc """
  Processes image data according to the given options.

  ## Options
  - `:width` - target width
  - `:height` - target height
  - `:crop` - crop mode (`:center`)
  - `:format` - output format ("webp", "jpeg", "png")
  - `:quality` - output quality (1-100, default 80)

  Returns `{:ok, processed_binary}` or `{:error, reason}`.
  """
  def process(data, opts) when is_binary(data) do
    if vix_available?() do
      do_process(data, opts)
    else
      {:error, :vix_not_available}
    end
  end

  defp do_process(data, opts) do
    width = opts[:width]
    height = opts[:height]
    crop = opts[:crop]
    format = opts[:format] || "jpeg"
    quality = opts[:quality] || 80

    try do
      {:ok, image} = Vix.Vips.Image.new_from_buffer(data)

      image =
        cond do
          width && height && crop == :center ->
            Vix.Vips.Operation.thumbnail_buffer!(data, width,
              height: height,
              crop: :VIPS_INTERESTING_CENTRE
            )

          width && height ->
            Vix.Vips.Operation.thumbnail_buffer!(data, width, height: height)

          width ->
            Vix.Vips.Operation.thumbnail_buffer!(data, width)

          true ->
            image
        end

      case format do
        "webp" ->
          {:ok, binary} = Vix.Vips.Image.write_to_buffer(image, ".webp[Q=#{quality}]")
          {:ok, binary}

        "png" ->
          {:ok, binary} = Vix.Vips.Image.write_to_buffer(image, ".png")
          {:ok, binary}

        _ ->
          {:ok, binary} = Vix.Vips.Image.write_to_buffer(image, ".jpg[Q=#{quality}]")
          {:ok, binary}
      end
    rescue
      e ->
        Logger.error("Image processing failed: #{inspect(e)}")
        {:error, {:processing_failed, e}}
    end
  end

  defp vix_available? do
    Code.ensure_loaded?(Vix.Vips.Image)
  end
end
