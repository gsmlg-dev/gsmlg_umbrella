defmodule GSMLG.BrowserAgent.ArtifactOutbox do
  @moduledoc "Journal-backed Artifact outbox retained until a matching central ACK."

  alias GSMLG.BrowserAgent.{ArtifactStore, Journal}

  def put(journal \\ Journal, state_dir, attrs, content, opts \\ []) do
    with {:ok, entry} <- ArtifactStore.prepare(state_dir, attrs, content, opts),
         :ok <- Journal.reserve_artifact(journal, attrs["artifact_id"], entry) do
      write_reserved(journal, attrs["artifact_id"], entry, content, opts)
    end
  end

  def pending(journal \\ Journal) do
    journal
    |> Journal.list(:artifact_outbox)
    |> Enum.flat_map(fn
      {_artifact_id, %{status: :pending} = entry} -> [entry.manifest]
      {_artifact_id, _entry} -> []
    end)
    |> Enum.sort_by(& &1["artifact_id"])
  end

  def read(journal \\ Journal, artifact_id) do
    with {:ok, %{status: :pending} = entry} <-
           Journal.get(journal, :artifact_outbox, artifact_id) do
      ArtifactStore.read(entry)
    else
      :error -> {:error, :artifact_not_found}
      {:ok, _not_pending} -> {:error, :artifact_not_found}
    end
  end

  def ack(journal \\ Journal, artifact_id, sha256, opts \\ []) do
    case Journal.get(journal, :artifact_outbox, artifact_id) do
      {:ok, %{status: :pending} = entry} ->
        acknowledge_pending(journal, artifact_id, sha256, entry, opts)

      {:ok, %{status: :acked} = entry} ->
        finish_ack(journal, artifact_id, entry, opts)

      _missing_or_not_pending ->
        replay_ack(journal, artifact_id, sha256)
    end
  end

  def recover(journal \\ Journal, state_dir, opts \\ []) do
    with :ok <- reconcile_entries(journal, opts) do
      entries = Journal.list(journal, :artifact_outbox)
      referenced_paths = Enum.map(entries, fn {_artifact_id, entry} -> entry.path end)

      active_paths =
        Enum.flat_map(entries, fn
          {_artifact_id, %{status: :writing, path: path}} -> [path]
          _other -> []
        end)

      cleanup_opts = Keyword.put(opts, :active_paths, active_paths)
      ArtifactStore.cleanup_untracked(state_dir, referenced_paths, cleanup_opts)
    end
  end

  defp acknowledge_pending(journal, artifact_id, sha256, entry, opts) do
    with true <- valid_ack?(entry, sha256),
         :ok <- Journal.put(journal, :artifact_outbox, artifact_id, %{entry | status: :acked}) do
      finish_ack(journal, artifact_id, entry, opts)
    else
      false -> {:error, :artifact_ack_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp finish_ack(journal, artifact_id, entry, opts) do
    with :ok <- ArtifactStore.delete(entry, opts),
         :ok <- put_ack_tombstone(journal, artifact_id, entry),
         :ok <- Journal.finish_artifact(journal, artifact_id) do
      :ok
    end
  end

  defp put_ack_tombstone(journal, artifact_id, entry) do
    tombstone =
      %{
        artifact_id: artifact_id,
        sha256: entry.manifest["sha256"]
      }
      |> put_tombstone_owner(entry.manifest)

    Journal.put(journal, :artifact_ack_tombstone, artifact_id, tombstone)
  end

  defp put_tombstone_owner(tombstone, %{"job_id" => job_id, "metadata" => metadata}) do
    Map.merge(tombstone, %{
      central_job_id: job_id,
      remote_execution_id: metadata["remote_execution_id"]
    })
  end

  defp put_tombstone_owner(tombstone, %{"session_id" => session_id, "metadata" => metadata}) do
    Map.merge(tombstone, %{
      central_session_id: session_id,
      remote_session_id: metadata["remote_session_id"]
    })
  end

  defp replay_ack(journal, artifact_id, sha256) do
    case Journal.get(journal, :artifact_ack_tombstone, artifact_id) do
      {:ok, %{sha256: expected}} when is_binary(sha256) ->
        if byte_size(expected) == byte_size(sha256) and :crypto.hash_equals(expected, sha256),
          do: :ok,
          else: {:error, :artifact_ack_mismatch}

      _missing ->
        {:error, :artifact_not_found}
    end
  end

  defp reconcile_entries(journal, opts) do
    journal
    |> Journal.list(:artifact_outbox)
    |> Enum.reduce_while(:ok, fn {artifact_id, _entry}, :ok ->
      case claim_and_reconcile_entry(journal, artifact_id, opts) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp claim_and_reconcile_entry(journal, artifact_id, opts) do
    case Journal.claim_artifact_recovery(journal, artifact_id) do
      {:ok, entry} -> reconcile_claimed_entry(journal, artifact_id, entry, opts)
      status when status in [:active, :skip] -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp reconcile_claimed_entry(journal, artifact_id, %{status: :recovering} = entry, opts) do
    case ArtifactStore.read(entry) do
      {:ok, _content} -> Journal.promote_artifact(journal, artifact_id)
      {:error, _reason} -> discard_entry(journal, artifact_id, entry, opts)
    end
  end

  defp reconcile_claimed_entry(journal, artifact_id, %{status: :acked} = entry, opts) do
    finish_ack(journal, artifact_id, entry, opts)
  end

  defp reconcile_claimed_entry(_journal, _artifact_id, _entry, _opts),
    do: {:error, :artifact_state_invalid}

  defp discard_entry(journal, artifact_id, entry, opts) do
    with :ok <- ArtifactStore.delete(entry, opts),
         :ok <- Journal.finish_artifact(journal, artifact_id) do
      :ok
    end
  end

  defp write_reserved(journal, artifact_id, entry, content, opts) do
    case checkpoint(opts, :after_reserve) do
      :ok -> commit_reserved(journal, artifact_id, entry, content, opts)
      {:error, _reason} = simulated_crash -> simulated_crash
    end
  end

  defp commit_reserved(journal, artifact_id, entry, content, opts) do
    case safe_commit(entry, content, opts) do
      :ok ->
        promote_committed(journal, artifact_id, entry, opts)

      {:error, :artifact_exists} = error ->
        finish_failed_reservation(journal, artifact_id, error)

      {:error, {:artifact_exists_cleanup_failed, _reason}} = error ->
        finish_failed_reservation(journal, artifact_id, error)

      {:error, _reason} = error ->
        abort_failed_write(journal, artifact_id, entry, opts, error)
    end
  end

  defp safe_commit(entry, content, opts) do
    case ArtifactStore.commit(entry, content, opts) do
      :ok -> :ok
      {:error, _reason} = error -> error
      _invalid -> {:error, :artifact_write_failed}
    end
  rescue
    _exception -> {:error, :artifact_write_failed}
  catch
    _kind, _reason -> {:error, :artifact_write_failed}
  end

  defp promote_committed(journal, artifact_id, entry, opts) do
    with :ok <- checkpoint(opts, :after_commit),
         :ok <- Journal.promote_artifact(journal, artifact_id) do
      {:ok, entry.manifest}
    end
  end

  defp abort_failed_write(journal, artifact_id, entry, opts, original_error) do
    case ArtifactStore.delete(entry, opts) do
      :ok -> finish_failed_reservation(journal, artifact_id, original_error)
      {:error, _reason} -> orphan_failed_reservation(journal, artifact_id, original_error)
    end
  end

  defp finish_failed_reservation(journal, artifact_id, original_error) do
    case Journal.finish_artifact(journal, artifact_id) do
      :ok -> original_error
      {:error, _reason} = journal_error -> journal_error
    end
  end

  defp orphan_failed_reservation(journal, artifact_id, original_error) do
    case Journal.orphan_artifact(journal, artifact_id) do
      :ok -> original_error
      {:error, _reason} = journal_error -> journal_error
    end
  end

  defp checkpoint(opts, name) do
    case Keyword.get(opts, :checkpoint) do
      callback when is_function(callback, 1) -> callback.(name)
      _none -> :ok
    end
  end

  defp valid_ack?(entry, sha256) when is_binary(sha256) do
    expected = entry.manifest["sha256"]
    byte_size(expected) == byte_size(sha256) and :crypto.hash_equals(expected, sha256)
  end

  defp valid_ack?(_entry, _sha256), do: false
end

defmodule GSMLG.BrowserAgent.ArtifactOutbox.Recovery do
  @moduledoc false

  use GenServer

  alias GSMLG.BrowserAgent.{ArtifactOutbox, Journal}

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      journal: Keyword.get(opts, :journal, Journal),
      state_dir: Keyword.fetch!(opts, :state_dir),
      interval_ms: Keyword.get(opts, :interval_ms, 30_000),
      recover_opts: Keyword.take(opts, [:directory_sync, :stale_after_ms])
    }

    _ = ArtifactOutbox.recover(state.journal, state.state_dir, state.recover_opts)
    schedule_recovery(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:recover, state) do
    _ = ArtifactOutbox.recover(state.journal, state.state_dir, state.recover_opts)
    schedule_recovery(state.interval_ms)
    {:noreply, state}
  end

  defp schedule_recovery(interval_ms), do: Process.send_after(self(), :recover, interval_ms)
end
