defmodule GSMLG.Storage.CleanupWorker do
  @moduledoc "Recovers expired S3 upload intents, purges tombstones and retries variants."

  use GenServer
  require Logger

  alias GSMLG.Storage
  alias GSMLG.Storage.{Catalog, ContentType}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    interval =
      opts[:interval] || Application.get_env(:gsmlg_storage, :cleanup_interval, :timer.hours(1))

    Process.send_after(self(), :cleanup, interval)
    {:ok, %{interval: interval, recovery_cursor: nil, variant_cursor: nil}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    next_state =
      case scan(state) do
        {:ok, next_state} -> next_state
        {:error, _reason} -> state
      end

    Process.send_after(self(), :cleanup, state.interval)
    {:noreply, next_state}
  end

  @doc "Scans durable S3 intents, including reservations with no committed Oban recovery job."
  def run_cleanup do
    case scan(%{recovery_cursor: nil, variant_cursor: nil}) do
      {:ok, _state} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp scan(state) do
    now = DateTime.utc_now()
    retention = Application.get_env(:gsmlg_storage, :retention_window, 30 * 24 * 3600)
    cutoff = DateTime.add(now, -retention, :second)

    with {:ok, files} <- Catalog.list() do
      recoverable =
        Enum.filter(
          files,
          &(expired_intent?(&1, now) or
              (&1.status == "deleted" and DateTime.before?(&1.updated_at, cutoff)))
        )

      variants =
        Enum.filter(
          files,
          &(&1.status == "active" and &1.variants == %{} and ContentType.image?(&1.content_type) and
              not expired_intent?(&1, now))
        )

      {recovery_batch, recovery_cursor} =
        batch(recoverable, Map.get(state, :recovery_cursor), 100)

      {variant_batch, variant_cursor} = batch(variants, Map.get(state, :variant_cursor), 50)

      (recovery_batch ++ variant_batch)
      |> Enum.each(fn file ->
        cond do
          expired_intent?(file, now) ->
            Storage.recover_upload(file)

          file.status == "deleted" and DateTime.before?(file.updated_at, cutoff) ->
            Storage.purge(file)

          file.status == "active" and file.variants == %{} and
              ContentType.image?(file.content_type) ->
            Storage.regenerate_variants(file)

          true ->
            :ok
        end
      end)

      {:ok, Map.merge(state, %{recovery_cursor: recovery_cursor, variant_cursor: variant_cursor})}
    else
      {:error, _reason} = error ->
        Logger.warning("Storage cleanup could not read S3 manifests")
        error
    end
  end

  # Advance even after a protected intent or failed variant attempt, so one
  # persistent failure cannot consume every later tick's bounded batch.
  defp batch(files, cursor, limit) do
    sorted = Enum.sort_by(files, & &1.id)

    {before_cursor, after_cursor} =
      Enum.split_while(sorted, &(not is_nil(cursor) and &1.id <= cursor))

    selected = Enum.take(after_cursor ++ before_cursor, limit)

    next_cursor =
      case List.last(selected) do
        nil -> cursor
        file -> file.id
      end

    {selected, next_cursor}
  end

  defp expired_intent?(file, now) do
    expiry =
      if file.status == "processing",
        do: file.metadata["upload_expires_at"],
        else: if(file.status == "active", do: file.metadata["sync_staging_expires_at"])

    case expiry && DateTime.from_iso8601(expiry) do
      {:ok, expires_at, _} -> not DateTime.after?(expires_at, now)
      _ -> false
    end
  end
end
