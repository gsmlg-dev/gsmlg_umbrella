defmodule GSMLG.AdminWeb.StorageLive.Config do
  use GSMLG.AdminWeb, :user_live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Storage — S3 Configuration")
     |> assign(active_menu: "storage_config")
     |> assign(config: load_config())}
  end

  defp load_config do
    access_key = System.get_env("AWS_ACCESS_KEY_ID")
    secret_key = System.get_env("AWS_SECRET_ACCESS_KEY")
    region = System.get_env("AWS_REGION") || System.get_env("AWS_DEFAULT_REGION")

    %{
      s3_bucket: Application.get_env(:gsmlg_storage, :s3_bucket, nil),
      max_file_size: Application.get_env(:gsmlg_storage, :max_file_size, nil),
      cleanup_interval: Application.get_env(:gsmlg_storage, :cleanup_interval, nil),
      retention_window: Application.get_env(:gsmlg_storage, :retention_window, nil),
      aws_region: region,
      aws_access_key_id: mask_key(access_key),
      aws_credentials_set: not is_nil(access_key) and not is_nil(secret_key)
    }
  end

  defp mask_key(nil), do: nil

  defp mask_key(key) when byte_size(key) > 8 do
    visible = String.slice(key, 0, 4)
    "#{visible}****#{String.slice(key, -4, 4)}"
  end

  defp mask_key(key), do: String.duplicate("*", byte_size(key))

  defp format_bytes(nil), do: "—"

  defp format_bytes(bytes) when bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"

  defp format_bytes(bytes) when bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp format_bytes(bytes), do: "#{bytes} B"

  defp format_duration(nil), do: "—"

  defp format_duration(ms) when ms >= 86_400_000,
    do: "#{div(ms, 86_400_000)} days"

  defp format_duration(ms) when ms >= 3_600_000,
    do: "#{div(ms, 3_600_000)} hours"

  defp format_duration(ms) when ms >= 60_000,
    do: "#{div(ms, 60_000)} min"

  defp format_duration(ms), do: "#{ms} ms"
end
