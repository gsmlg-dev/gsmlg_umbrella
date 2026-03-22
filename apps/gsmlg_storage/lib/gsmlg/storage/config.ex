defmodule GSMLG.Storage.Config do
  @moduledoc """
  Configuration for GSMLG.Storage.
  Provides defaults and runtime configuration access.
  """

  @default_config %{
    s3_bucket: "gsmlg-storage",
    max_file_size: 5 * 1024 * 1024 * 1024,
    cleanup_interval: 3_600_000,
    retention_window: 30 * 24 * 3600,
    allowed_types: %{
      "avatar" => ~w(image/jpeg image/png image/webp image/gif),
      "document" => ~w(application/pdf text/plain text/html application/json),
      "attachment" => :any
    },
    variant_definitions: %{
      "avatar" => %{
        "thumb" => [width: 150, height: 150, crop: :center, format: "webp"],
        "medium" => [width: 400, height: 400, format: "webp"]
      },
      "document" => %{
        "preview" => [width: 800, height: 600, format: "webp"]
      }
    }
  }

  def defaults, do: @default_config
end
