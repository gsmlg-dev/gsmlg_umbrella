defmodule GSMLG.Storage.CleanupWorker do
  @moduledoc """
  Periodic worker that:
  1. Purges S3 objects for files with status "deleted" older than the retention window
  2. Retries variant generation for active files with empty variants
  """

  use GenServer
  require Logger

  alias GSMLG.Repo
  alias GSMLG.Storage
  alias GSMLG.Storage.{StorageFile, ContentType}

  import Ecto.Query

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = opts[:interval] || cleanup_interval()
    schedule_cleanup(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    run_cleanup()
    schedule_cleanup(state.interval)
    {:noreply, state}
  end

  defp schedule_cleanup(interval) do
    Process.send_after(self(), :cleanup, interval)
  end

  defp run_cleanup do
    Logger.info("Storage cleanup worker starting")
    purged = purge_deleted_files()
    retried = retry_variant_generation()
    Logger.info("Storage cleanup complete: purged=#{purged}, variant_retries=#{retried}")
  end

  defp purge_deleted_files do
    retention = retention_window()
    cutoff = DateTime.add(DateTime.utc_now(), -retention, :second)

    files =
      StorageFile
      |> where([f], f.status == "deleted" and f.updated_at < ^cutoff)
      |> limit(100)
      |> Repo.all()

    Enum.count(files, fn file ->
      case Storage.purge(file) do
        {:ok, _} -> true
        _ -> false
      end
    end)
  end

  defp retry_variant_generation do
    files =
      StorageFile
      |> where([f], f.status == "active" and f.variants == ^%{})
      |> limit(50)
      |> Repo.all()
      |> Enum.filter(fn f -> ContentType.image?(f.content_type) end)

    Enum.count(files, fn file ->
      case Storage.regenerate_variants(file) do
        :ok -> true
        _ -> false
      end
    end)
  end

  defp cleanup_interval do
    Application.get_env(:gsmlg_storage, :cleanup_interval, :timer.hours(1))
  end

  defp retention_window do
    Application.get_env(:gsmlg_storage, :retention_window, 30 * 24 * 3600)
  end
end
