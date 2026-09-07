defmodule GSMLG.BrowserAgent.Journal do
  @moduledoc """
  Single-owner durable DETS journal for Browser Agent state.

  Terminal action and session replay is retained for the configured maximum age, subject to the
  configured record and serialized-byte caps. An exact replay older than that horizon is not
  guaranteed. Unresolved actions, uncertain outcomes, live sessions, and lease authority are never
  retention candidates.
  """

  use GenServer

  @format {:gsmlg_browser_agent, 1}
  @record_version 1
  @default_max_request_entries 10_000
  @default_max_event_executions 1_000
  @default_max_unacked_events 100_000
  @default_max_workflow_entries 10_000
  @default_terminal_max_records 10_000
  @default_terminal_max_age_ms 2_592_000_000
  @default_terminal_max_bytes 67_108_864
  @default_recovery_scan_max_records 10_000
  @terminal_prune_batch 64
  @terminal_namespaces [:pending_action, :browser_session]
  @uuid ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def put(server \\ __MODULE__, namespace, key, value) do
    GenServer.call(server, {:put, namespace, key, value})
  end

  def get(server \\ __MODULE__, namespace, key) do
    GenServer.call(server, {:get, namespace, key})
  end

  def delete(server \\ __MODULE__, namespace, key) do
    GenServer.call(server, {:delete, namespace, key})
  end

  def list(server \\ __MODULE__, namespace) do
    GenServer.call(server, {:list, namespace})
  end

  @doc false
  def recovery_list(server \\ __MODULE__, namespace, opts) do
    GenServer.call(server, {:recovery_list, namespace, opts})
  end

  @doc false
  def browser_session_by_central_id(server \\ __MODULE__, central_session_id) do
    GenServer.call(server, {:browser_session_by_central_id, central_session_id})
  end

  @doc false
  def begin_request_generation(server) do
    GenServer.call(server, :begin_request_generation)
  end

  @doc false
  def request_claim(server, request_id, idempotency_key, fingerprint, request, generation) do
    GenServer.call(
      server,
      {:request_claim, request_id, idempotency_key, fingerprint, request, generation}
    )
  end

  @doc false
  def request_complete(server, request_id, fingerprint, result) do
    GenServer.call(server, {:request_complete, request_id, fingerprint, result})
  end

  @doc false
  def request_defer(server, request_id, fingerprint) do
    GenServer.call(server, {:request_defer, request_id, fingerprint})
  end

  @doc false
  def append_event(server, execution_id, event) do
    GenServer.call(server, {:append_event, execution_id, event})
  end

  @doc false
  def ack_events(server, execution_id, sequence) do
    GenServer.call(server, {:ack_events, execution_id, sequence})
  end

  @doc false
  def mark_event_emitted(server, execution_id, sequence) do
    GenServer.call(server, {:mark_event_emitted, execution_id, sequence})
  end

  @doc false
  def cleanup_event_execution(server, execution_id) do
    GenServer.call(server, {:cleanup_event_execution, execution_id})
  end

  @doc false
  def reserve_artifact(server, artifact_id, entry) do
    GenServer.call(server, {:reserve_artifact, artifact_id, entry})
  end

  @doc false
  def promote_artifact(server, artifact_id) do
    GenServer.call(server, {:promote_artifact, artifact_id})
  end

  @doc false
  def claim_artifact_recovery(server, artifact_id) do
    GenServer.call(server, {:claim_artifact_recovery, artifact_id})
  end

  @doc false
  def finish_artifact(server, artifact_id) do
    GenServer.call(server, {:finish_artifact, artifact_id})
  end

  @doc false
  def orphan_artifact(server, artifact_id) do
    GenServer.call(server, {:orphan_artifact, artifact_id})
  end

  @doc false
  def workflow_claim(server, checkpoint, max_active) do
    GenServer.call(server, {:workflow_claim, checkpoint, max_active})
  end

  @doc false
  def workflow_get(server, remote_execution_id) do
    GenServer.call(server, {:workflow_get, remote_execution_id})
  end

  @doc false
  def workflow_by_central_job_id(server, central_job_id) do
    GenServer.call(server, {:workflow_by_central_job_id, central_job_id})
  end

  @doc false
  def workflow_list(server), do: GenServer.call(server, :workflow_list)

  @doc false
  def workflow_takeover(server, remote_execution_id, generation) do
    GenServer.call(server, {:workflow_takeover, remote_execution_id, generation})
  end

  @doc false
  def workflow_update(server, checkpoint, generation) do
    GenServer.call(server, {:workflow_update, checkpoint, generation})
  end

  @doc false
  def append_event_once(server, execution_id, event_key, event) do
    GenServer.call(server, {:append_event_once, execution_id, event_key, event})
  end

  @doc false
  def event_unacked(server, execution_id) do
    GenServer.call(server, {:event_unacked, execution_id})
  end

  @doc false
  def event_execution_ids(server), do: GenServer.call(server, :event_execution_ids)

  @doc false
  def event_last_sequence(server, execution_id) do
    GenServer.call(server, {:event_last_sequence, execution_id})
  end

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    table = Keyword.get(opts, :dets_name, __MODULE__)
    :ok = File.mkdir_p(Path.dirname(path))

    case :dets.open_file(table, file: String.to_charlist(path), type: :set, repair: true) do
      {:ok, ^table} ->
        state = %{
          table: table,
          sync: Keyword.get(opts, :sync, &:dets.sync/1),
          max_request_entries:
            positive_limit(opts, :max_request_entries, @default_max_request_entries),
          max_event_executions:
            positive_limit(opts, :max_event_executions, @default_max_event_executions),
          max_unacked_events:
            positive_limit(opts, :max_unacked_events, @default_max_unacked_events),
          max_workflow_entries:
            positive_limit(opts, :max_workflow_entries, @default_max_workflow_entries),
          terminal_max_records:
            positive_limit(
              opts,
              :journal_terminal_max_records,
              @default_terminal_max_records
            ),
          terminal_max_age_ms:
            positive_limit(opts, :journal_terminal_max_age_ms, @default_terminal_max_age_ms),
          terminal_max_bytes:
            positive_limit(opts, :journal_terminal_max_bytes, @default_terminal_max_bytes),
          recovery_scan_max_records:
            positive_limit(
              opts,
              :journal_recovery_scan_max_records,
              @default_recovery_scan_max_records
            ),
          clock_ms: Keyword.get(opts, :clock_ms, fn -> System.system_time(:millisecond) end),
          artifact_generation: generate_generation(),
          artifact_monitors: %{},
          terminal_retention: %{},
          profile_leases: %{},
          browser_sessions: %{},
          browser_session_keys: %{},
          workflow_checkpoints: %{},
          workflow_central_index: %{},
          workflow_idempotency_index: %{},
          event_sequences: %{},
          event_emitted: %{},
          event_unacked: %{},
          event_unacked_count: 0,
          event_dedup: %{}
        }

        with :ok <- reconcile_request_indexes(state.table, state.sync),
             {:ok, state} <- initialize_authority_indexes(state),
             {:ok, state} <- initialize_workflow_indexes(state),
             {:ok, state} <- initialize_event_indexes(state),
             {:ok, state} <- initialize_terminal_retention(state),
             {:ok, state} <- adopt_live_artifact_owners(state) do
          {:ok, state}
        else
          {:error, reason} -> {:stop, reason}
        end

      {:error, reason} ->
        {:stop, {:journal_open_failed, reason}}
    end
  end

  @impl true
  def handle_call({:put, namespace, key, value}, _from, state) do
    value = compact_terminal(state, namespace, value)
    put_record(state, namespace, key, value)
  end

  def handle_call({:get, namespace, key}, _from, state) do
    result =
      if retention_visible?(state, namespace, record_key(namespace, key)),
        do: fetch(state.table, namespace, key),
        else: :error

    {:reply, result, state}
  end

  def handle_call({:delete, namespace, key}, _from, state) do
    delete_record(state, namespace, key)
  end

  def handle_call({:list, namespace}, _from, state) do
    {:reply, list_visible_namespace(state, namespace), state}
  end

  def handle_call({:recovery_list, namespace, opts}, _from, state) do
    {:reply, bounded_recovery_list(state, namespace, opts), state}
  end

  def handle_call({:browser_session_by_central_id, central_session_id}, _from, state) do
    result =
      with true <- is_binary(central_session_id),
           {:ok, records} <- bounded_namespace_records(state, :browser_session) do
        Enum.find_value(records, :error, fn
          {{@format, :browser_session, _key} = key,
           %{
             version: @record_version,
             value: %{central_session_id: ^central_session_id} = session
           }} ->
            if retention_visible?(state, :browser_session, key), do: {:ok, session}, else: false

          _other ->
            false
        end)
      else
        false -> :error
        {:error, _reason} = error -> error
      end

    {:reply, result, state}
  end

  def handle_call(:begin_request_generation, _from, state) do
    generation = generate_generation()

    result =
      persist(
        state.table,
        [{record_key(:metadata, :request_generation), record(generation)}],
        state.sync
      )

    reply = if result == :ok, do: {:ok, generation}, else: result
    mutation_reply(reply, state)
  end

  def handle_call(
        {:request_claim, request_id, idempotency_key, fingerprint, request, generation},
        _from,
        state
      ) do
    result =
      claim_request(
        state.table,
        request_id,
        idempotency_key,
        fingerprint,
        request,
        generation,
        state.sync,
        state.max_request_entries
      )

    mutation_reply(result, state)
  end

  def handle_call({:request_complete, request_id, fingerprint, result}, _from, state) do
    reply = complete_request(state.table, request_id, fingerprint, result, state.sync)
    mutation_reply(reply, state)
  end

  def handle_call({:request_defer, request_id, fingerprint}, _from, state) do
    reply = defer_request(state.table, request_id, fingerprint, state.sync)
    mutation_reply(reply, state)
  end

  def handle_call({:append_event, execution_id, event}, _from, state) do
    event_key = {:unkeyed, state.clock_ms.(), System.unique_integer([:positive])}
    event_append_reply(state, execution_id, event_key, event, false)
  end

  def handle_call({:append_event_once, execution_id, event_key, event}, _from, state) do
    event_append_reply(state, execution_id, event_key, event, true)
  end

  def handle_call({:ack_events, execution_id, sequence}, _from, state) do
    last_appended = Map.get(state.event_sequences, execution_id)
    last_emitted = Map.get(state.event_emitted, execution_id, 0)

    cond do
      not valid_remote_execution_id?(execution_id) or not is_integer(sequence) or sequence < 0 ->
        {:reply, {:error, :invalid_event_ack}, state}

      is_nil(last_appended) ->
        {:reply, {:error, :event_execution_not_found}, state}

      sequence > last_emitted ->
        {:reply, {:error, :event_ack_ahead}, state}

      true ->
        acknowledge_events(state, execution_id, sequence)
    end
  end

  def handle_call({:mark_event_emitted, execution_id, sequence}, _from, state) do
    last_appended = Map.get(state.event_sequences, execution_id)
    last_emitted = Map.get(state.event_emitted, execution_id, 0)

    cond do
      not valid_remote_execution_id?(execution_id) or not is_integer(sequence) or sequence <= 0 ->
        {:reply, {:error, :invalid_event_sequence}, state}

      is_nil(last_appended) ->
        {:reply, {:error, :event_execution_not_found}, state}

      sequence > last_appended ->
        {:reply, {:error, :event_sequence_ahead}, state}

      sequence <= last_emitted ->
        {:reply, :ok, state}

      sequence != last_emitted + 1 ->
        {:reply, {:error, :event_emit_gap}, state}

      true ->
        record = {record_key(:event_emitted, execution_id), record(sequence)}

        case persist(state.table, [record], state.sync) do
          :ok ->
            next = %{state | event_emitted: Map.put(state.event_emitted, execution_id, sequence)}
            {:reply, :ok, next}

          {:error, _reason} = error ->
            mutation_reply(error, state)
        end
    end
  end

  def handle_call({:cleanup_event_execution, execution_id}, _from, state) do
    if Map.get(state.event_unacked, execution_id, MapSet.new()) |> MapSet.size() > 0 do
      {:reply, {:error, :event_unacked}, state}
    else
      dedup_keys =
        state.event_dedup
        |> Map.keys()
        |> Enum.flat_map(fn
          {^execution_id, event_key} -> [record_key(:event_dedup, {execution_id, event_key})]
          _other -> []
        end)

      keys =
        [
          record_key(:event_sequence, execution_id),
          record_key(:event_emitted, execution_id)
          | dedup_keys
        ]

      case delete_keys(state.table, keys, state.sync) do
        :ok ->
          dedup = Map.reject(state.event_dedup, fn {{id, _key}, _event} -> id == execution_id end)

          next = %{
            state
            | event_sequences: Map.delete(state.event_sequences, execution_id),
              event_emitted: Map.delete(state.event_emitted, execution_id),
              event_unacked: Map.delete(state.event_unacked, execution_id),
              event_dedup: dedup
          }

          {:reply, :ok, next}

        {:error, _reason} = error ->
          mutation_reply(error, state)
      end
    end
  end

  def handle_call({:event_unacked, execution_id}, _from, state) do
    events =
      state.event_unacked
      |> Map.get(execution_id, MapSet.new())
      |> Enum.sort()
      |> Enum.flat_map(fn sequence ->
        case fetch(state.table, :event_outbox, {execution_id, sequence}) do
          {:ok, event} -> [event]
          :error -> []
        end
      end)

    {:reply, events, state}
  end

  def handle_call(:event_execution_ids, _from, state) do
    {:reply, state.event_sequences |> Map.keys() |> Enum.sort(), state}
  end

  def handle_call({:event_last_sequence, execution_id}, _from, state) do
    {:reply, Map.get(state.event_sequences, execution_id, 0), state}
  end

  def handle_call({:workflow_claim, checkpoint, max_active}, _from, state) do
    workflow_claim_reply(state, checkpoint, max_active)
  end

  def handle_call({:workflow_get, remote_execution_id}, _from, state) do
    {:reply, map_fetch(state.workflow_checkpoints, remote_execution_id), state}
  end

  def handle_call({:workflow_by_central_job_id, central_job_id}, _from, state) do
    reply =
      with {:ok, remote_id} <- Map.fetch(state.workflow_central_index, central_job_id),
           {:ok, checkpoint} <- Map.fetch(state.workflow_checkpoints, remote_id) do
        {:ok, checkpoint}
      else
        :error -> :error
      end

    {:reply, reply, state}
  end

  def handle_call(:workflow_list, _from, state) do
    {:reply, Enum.sort_by(state.workflow_checkpoints, &elem(&1, 0)), state}
  end

  def handle_call({:workflow_takeover, remote_execution_id, generation}, _from, state) do
    with true <- valid_workflow_id?(generation),
         {:ok, checkpoint} <- Map.fetch(state.workflow_checkpoints, remote_execution_id),
         false <- terminal_workflow?(checkpoint),
         updated = %{checkpoint | runner_generation: generation},
         :ok <- persist_workflow_checkpoint(state, updated) do
      next = put_in(state, [:workflow_checkpoints, remote_execution_id], updated)
      {:reply, {:ok, updated}, next}
    else
      :error -> {:reply, {:error, :workflow_not_found}, state}
      true -> {:reply, {:error, :workflow_terminal}, state}
      false -> {:reply, {:error, :invalid_workflow_checkpoint}, state}
      {:error, _reason} = error -> mutation_reply(error, state)
    end
  end

  def handle_call({:workflow_update, checkpoint, generation}, _from, state) do
    workflow_update_reply(state, checkpoint, generation)
  end

  def handle_call({:reserve_artifact, artifact_id, entry}, {owner_pid, _tag}, state) do
    case fetch(state.table, :artifact_outbox, artifact_id) do
      :error -> reserve_artifact(state, artifact_id, entry, owner_pid)
      {:ok, _existing} -> {:reply, {:error, :artifact_exists}, state}
    end
  end

  def handle_call({:promote_artifact, artifact_id}, {owner_pid, _tag}, state) do
    case fetch(state.table, :artifact_outbox, artifact_id) do
      {:ok, %{status: status} = entry} when status in [:writing, :recovering] ->
        if artifact_owned_by?(entry, owner_pid, state.artifact_generation) do
          pending =
            entry
            |> Map.drop([:owner_pid, :owner_generation, :owner_kind])
            |> Map.put(:status, :pending)

          result = persist_artifact(state, artifact_id, pending)
          mutation_reply(result, drop_artifact_monitor(state, artifact_id))
        else
          {:reply, {:error, :artifact_reservation_not_owned}, state}
        end

      {:ok, %{status: :pending}} ->
        {:reply, :ok, state}

      _missing_or_invalid ->
        {:reply, {:error, :artifact_not_reserved}, state}
    end
  end

  def handle_call({:claim_artifact_recovery, artifact_id}, {owner_pid, _tag}, state) do
    claim_artifact_recovery(state, artifact_id, owner_pid)
  end

  def handle_call({:finish_artifact, artifact_id}, {owner_pid, _tag}, state) do
    finish_artifact(state, artifact_id, owner_pid)
  end

  def handle_call({:orphan_artifact, artifact_id}, {owner_pid, _tag}, state) do
    orphan_artifact(state, artifact_id, owner_pid)
  end

  @impl true
  def handle_info({:DOWN, ref, :process, owner_pid, _reason}, state) do
    case Map.pop(state.artifact_monitors, ref) do
      {{artifact_id, ^owner_pid}, monitors} ->
        state = %{state | artifact_monitors: monitors}
        orphan_dead_artifact(state, artifact_id, owner_pid)

      {nil, _monitors} ->
        {:noreply, state}
    end
  end

  defp reserve_artifact(state, artifact_id, entry, owner_pid) do
    owned =
      Map.merge(entry, %{
        status: :writing,
        owner_pid: owner_pid,
        owner_generation: state.artifact_generation,
        owner_kind: :writer
      })

    case persist_artifact(state, artifact_id, owned) do
      :ok ->
        {:reply, :ok, monitor_artifact_owner(state, artifact_id, owner_pid)}

      {:error, _reason} = error ->
        mutation_reply(error, state)
    end
  end

  defp claim_artifact_recovery(state, artifact_id, owner_pid) do
    case fetch(state.table, :artifact_outbox, artifact_id) do
      {:ok, %{status: :writing} = entry} ->
        if live_artifact_owner?(entry, state.artifact_generation) do
          {:reply, :active, state}
        else
          persist_recovery_claim(state, artifact_id, entry, owner_pid)
        end

      {:ok, %{status: :orphaned} = entry} ->
        persist_recovery_claim(state, artifact_id, entry, owner_pid)

      {:ok, %{status: :recovering} = entry} ->
        if artifact_owned_by?(entry, owner_pid, state.artifact_generation) do
          {:reply, {:ok, entry}, state}
        else
          if live_artifact_owner?(entry, state.artifact_generation) do
            {:reply, :active, state}
          else
            persist_recovery_claim(state, artifact_id, entry, owner_pid)
          end
        end

      {:ok, %{status: :acked} = entry} ->
        {:reply, {:ok, entry}, state}

      {:ok, %{status: :pending}} ->
        {:reply, :skip, state}

      :error ->
        {:reply, :skip, state}

      {:ok, _invalid} ->
        {:reply, {:error, :artifact_state_invalid}, state}
    end
  end

  defp persist_recovery_claim(state, artifact_id, entry, owner_pid) do
    recovering =
      Map.merge(entry, %{
        status: :recovering,
        owner_pid: owner_pid,
        owner_generation: state.artifact_generation,
        owner_kind: :recovery
      })

    case persist_artifact(state, artifact_id, recovering) do
      :ok ->
        state =
          state
          |> drop_artifact_monitor(artifact_id)
          |> monitor_artifact_owner(artifact_id, owner_pid)

        {:reply, {:ok, recovering}, state}

      {:error, _reason} = error ->
        mutation_reply(error, state)
    end
  end

  defp finish_artifact(state, artifact_id, owner_pid) do
    case fetch(state.table, :artifact_outbox, artifact_id) do
      {:ok, %{status: :acked}} ->
        delete_finished_artifact(state, artifact_id)

      {:ok, %{status: status} = entry} when status in [:writing, :recovering] ->
        if artifact_owned_by?(entry, owner_pid, state.artifact_generation) do
          delete_finished_artifact(state, artifact_id)
        else
          {:reply, {:error, :artifact_reservation_not_owned}, state}
        end

      :error ->
        {:reply, :ok, state}

      {:ok, _other} ->
        {:reply, {:error, :artifact_state_invalid}, state}
    end
  end

  defp delete_finished_artifact(state, artifact_id) do
    result = delete_keys(state.table, [record_key(:artifact_outbox, artifact_id)], state.sync)
    mutation_reply(result, drop_artifact_monitor(state, artifact_id))
  end

  defp orphan_artifact(state, artifact_id, owner_pid) do
    case fetch(state.table, :artifact_outbox, artifact_id) do
      {:ok, %{status: status} = entry} when status in [:writing, :recovering] ->
        if artifact_owned_by?(entry, owner_pid, state.artifact_generation) do
          orphan = orphaned_artifact(entry)
          result = persist_artifact(state, artifact_id, orphan)
          mutation_reply(result, drop_artifact_monitor(state, artifact_id))
        else
          {:reply, {:error, :artifact_reservation_not_owned}, state}
        end

      :error ->
        {:reply, :ok, state}

      {:ok, _other} ->
        {:reply, {:error, :artifact_state_invalid}, state}
    end
  end

  defp orphan_dead_artifact(state, artifact_id, owner_pid) do
    case fetch(state.table, :artifact_outbox, artifact_id) do
      {:ok, %{status: status, owner_pid: ^owner_pid} = entry}
      when status in [:writing, :recovering] ->
        case persist_artifact(state, artifact_id, orphaned_artifact(entry)) do
          :ok -> {:noreply, state}
          {:error, _reason} = error -> mutation_noreply(error, state)
        end

      _not_owned ->
        {:noreply, state}
    end
  end

  defp orphaned_artifact(entry) do
    entry
    |> Map.drop([:owner_pid, :owner_generation, :owner_kind])
    |> Map.put(:status, :orphaned)
  end

  defp live_artifact_owner?(entry, generation) do
    Map.get(entry, :owner_generation) == generation and
      is_pid(Map.get(entry, :owner_pid)) and Process.alive?(entry.owner_pid)
  end

  defp artifact_owned_by?(entry, owner_pid, generation) do
    Map.get(entry, :owner_pid) == owner_pid and Map.get(entry, :owner_generation) == generation
  end

  defp monitor_artifact_owner(state, artifact_id, owner_pid) do
    ref = Process.monitor(owner_pid)
    put_in(state, [:artifact_monitors, ref], {artifact_id, owner_pid})
  end

  defp adopt_live_artifact_owners(state) do
    state.table
    |> list_namespace(:artifact_outbox)
    |> Enum.reduce_while({:ok, state}, fn
      {artifact_id, %{status: status, owner_pid: owner_pid} = entry}, {:ok, current_state}
      when status in [:writing, :recovering] ->
        if local_owner_alive?(owner_pid) do
          adopted = Map.put(entry, :owner_generation, current_state.artifact_generation)

          case persist_artifact(current_state, artifact_id, adopted) do
            :ok ->
              {:cont, {:ok, monitor_artifact_owner(current_state, artifact_id, owner_pid)}}

            {:error, _reason} = error ->
              {:halt, error}
          end
        else
          {:cont, {:ok, current_state}}
        end

      _not_owned, accumulator ->
        {:cont, accumulator}
    end)
  end

  defp local_owner_alive?(owner_pid) when is_pid(owner_pid) do
    node(owner_pid) == node() and Process.alive?(owner_pid)
  end

  defp local_owner_alive?(_owner_pid), do: false

  defp drop_artifact_monitor(state, artifact_id) do
    {matching, remaining} =
      Enum.split_with(state.artifact_monitors, fn {_ref, {monitored_id, _pid}} ->
        monitored_id == artifact_id
      end)

    Enum.each(matching, fn {ref, _owner} -> Process.demonitor(ref, [:flush]) end)
    %{state | artifact_monitors: Map.new(remaining)}
  end

  defp persist_artifact(state, artifact_id, entry) do
    persist(
      state.table,
      [{record_key(:artifact_outbox, artifact_id), record(entry)}],
      state.sync
    )
  end

  defp mutation_reply({:error, {:journal_write_failed, _reason}} = error, state) do
    {:stop, {:journal_unusable, error}, error, state}
  end

  defp mutation_reply(result, state), do: {:reply, result, state}

  defp mutation_noreply({:error, {:journal_write_failed, _reason}} = error, state) do
    {:stop, {:journal_unusable, error}, state}
  end

  @impl true
  def terminate(_reason, state) do
    _ = :dets.close(state.table)
    :ok
  end

  defp claim_request(
         table,
         request_id,
         idempotency_key,
         fingerprint,
         request,
         generation,
         sync,
         max_request_entries
       ) do
    case fetch(table, :request_dedup, request_id) do
      {:ok, entry} ->
        claim_existing(table, entry, fingerprint, generation, :request_payload_collision, sync)

      :error ->
        claim_by_idempotency(
          table,
          request_id,
          idempotency_key,
          fingerprint,
          request,
          generation,
          sync,
          max_request_entries
        )
    end
  end

  defp claim_by_idempotency(
         table,
         request_id,
         idempotency_key,
         fingerprint,
         request,
         generation,
         sync,
         max_request_entries
       ) do
    case fetch(table, :request_idempotency, idempotency_key) do
      {:ok, entry} ->
        claim_existing(
          table,
          entry,
          fingerprint,
          generation,
          :idempotency_payload_collision,
          sync
        )

      :error ->
        persist_claim(
          table,
          request_id,
          idempotency_key,
          fingerprint,
          request,
          generation,
          sync,
          max_request_entries
        )
    end
  end

  defp persist_claim(
         table,
         request_id,
         idempotency_key,
         fingerprint,
         request,
         generation,
         sync,
         max_request_entries
       ) do
    with :ok <- ensure_request_capacity(table, max_request_entries, sync) do
      entry = %{
        request_id: request_id,
        idempotency_key: idempotency_key,
        fingerprint: fingerprint,
        request: request,
        generation: generation,
        status: :running,
        result: nil
      }

      case persist_request_entry(table, entry, sync) do
        :ok -> :execute
        {:error, _reason} = error -> error
      end
    end
  end

  defp claim_existing(
         _table,
         %{fingerprint: existing},
         fingerprint,
         _generation,
         collision,
         _sync
       )
       when existing != fingerprint,
       do: {:error, collision}

  defp claim_existing(
         _table,
         %{fingerprint: fingerprint, status: :completed, result: result},
         fingerprint,
         _generation,
         _collision,
         _sync
       ),
       do: {:replay, result}

  defp claim_existing(
         _table,
         %{fingerprint: fingerprint, status: status, request_id: request_id} = entry,
         fingerprint,
         generation,
         _collision,
         _sync
       )
       when status in [:running, :recovering] and
              is_map_key(entry, :generation) and entry.generation == generation,
       do: {:in_progress, request_id}

  defp claim_existing(
         table,
         %{fingerprint: fingerprint, status: status} = entry,
         fingerprint,
         generation,
         _collision,
         sync
       )
       when status in [:running, :recovering, :recoverable] do
    recovering = Map.merge(entry, %{generation: generation, status: :recovering})

    case persist_request_entry(table, recovering, sync) do
      :ok ->
        {:recover,
         %{
           request_id: recovering.request_id,
           request: Map.get(recovering, :request)
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp claim_existing(
         _table,
         %{fingerprint: fingerprint},
         fingerprint,
         _generation,
         _collision,
         _sync
       ),
       do: {:error, :request_state_invalid}

  defp complete_request(table, request_id, fingerprint, result, sync) do
    case fetch(table, :request_dedup, request_id) do
      {:ok, %{fingerprint: ^fingerprint} = entry} ->
        completed = %{entry | status: :completed, result: result}

        persist(
          table,
          [
            {record_key(:request_dedup, request_id), record(completed)},
            {record_key(:request_idempotency, entry.idempotency_key), record(completed)}
          ],
          sync
        )

      _missing_or_changed ->
        {:error, :request_not_claimed}
    end
  end

  defp defer_request(table, request_id, fingerprint, sync) do
    case fetch(table, :request_dedup, request_id) do
      {:ok, %{fingerprint: ^fingerprint} = entry} ->
        persist_request_entry(table, %{entry | status: :recoverable, result: nil}, sync)

      _missing_or_changed ->
        {:error, :request_not_claimed}
    end
  end

  defp persist_request_entry(table, entry, sync) do
    persist(
      table,
      [
        {record_key(:request_dedup, entry.request_id), record(entry)},
        {record_key(:request_idempotency, entry.idempotency_key), record(entry)}
      ],
      sync
    )
  end

  defp ensure_request_capacity(table, max_request_entries, sync) do
    entries = list_namespace(table, :request_dedup)

    if length(entries) < max_request_entries do
      :ok
    else
      case Enum.find(entries, fn {_request_id, entry} -> entry.status == :completed end) do
        {request_id, entry} ->
          delete_keys(
            table,
            [
              record_key(:request_dedup, request_id),
              record_key(:request_idempotency, entry.idempotency_key)
            ],
            sync
          )

        nil ->
          {:error, :request_capacity_exceeded}
      end
    end
  end

  defp workflow_claim_reply(state, checkpoint, max_active) do
    with :ok <- validate_workflow_claim(checkpoint, max_active) do
      remote_id = checkpoint.remote_execution_id
      central_id = checkpoint.central_job_id
      idempotency_id = {checkpoint.workflow, checkpoint.idempotency_key}

      cond do
        Map.has_key?(state.workflow_central_index, central_id) ->
          workflow_replay_or_collision(
            state,
            Map.fetch!(state.workflow_central_index, central_id),
            checkpoint,
            :central_job_id_collision
          )

        Map.has_key?(state.workflow_idempotency_index, idempotency_id) ->
          workflow_replay_or_collision(
            state,
            Map.fetch!(state.workflow_idempotency_index, idempotency_id),
            checkpoint,
            :workflow_idempotency_collision
          )

        Map.has_key?(state.workflow_checkpoints, remote_id) ->
          workflow_replay_or_collision(
            state,
            remote_id,
            checkpoint,
            :remote_execution_id_collision
          )

        map_size(state.workflow_checkpoints) >= state.max_workflow_entries ->
          {:reply, {:error, :workflow_journal_capacity_exceeded}, state}

        active_workflow_count(state.workflow_checkpoints) >= max_active ->
          {:reply, {:error, :workflow_capacity_exceeded}, state}

        true ->
          persist_new_workflow(state, checkpoint)
      end
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  defp workflow_replay_or_collision(state, remote_id, proposed, collision) do
    existing = Map.fetch!(state.workflow_checkpoints, remote_id)

    if existing.request_fingerprint == proposed.request_fingerprint do
      {:reply, {:replay, existing}, state}
    else
      {:reply, {:error, collision}, state}
    end
  end

  defp persist_new_workflow(state, checkpoint) do
    remote_id = checkpoint.remote_execution_id
    central_id = checkpoint.central_job_id
    idempotency_id = {checkpoint.workflow, checkpoint.idempotency_key}

    records = [
      {record_key(:workflow_checkpoint, remote_id), record(checkpoint)},
      {record_key(:workflow_central_index, central_id), record(remote_id)},
      {record_key(:workflow_idempotency_index, idempotency_id), record(remote_id)}
    ]

    case persist(state.table, records, state.sync) do
      :ok ->
        next = %{
          state
          | workflow_checkpoints: Map.put(state.workflow_checkpoints, remote_id, checkpoint),
            workflow_central_index: Map.put(state.workflow_central_index, central_id, remote_id),
            workflow_idempotency_index:
              Map.put(state.workflow_idempotency_index, idempotency_id, remote_id)
        }

        {:reply, {:execute, checkpoint}, next}

      {:error, _reason} = error ->
        mutation_reply(error, state)
    end
  end

  defp workflow_update_reply(state, checkpoint, generation) do
    with true <- valid_workflow_checkpoint?(checkpoint),
         true <- valid_workflow_id?(generation),
         {:ok, current} <- Map.fetch(state.workflow_checkpoints, checkpoint.remote_execution_id),
         true <-
           current.runner_generation == generation and checkpoint.runner_generation == generation,
         :ok <- validate_workflow_identity(current, checkpoint),
         :ok <- validate_workflow_terminal_transition(current, checkpoint),
         :ok <- persist_workflow_checkpoint(state, checkpoint) do
      next = put_in(state, [:workflow_checkpoints, checkpoint.remote_execution_id], checkpoint)
      {:reply, :ok, next}
    else
      false -> {:reply, {:error, :stale_workflow_generation}, state}
      :error -> {:reply, {:error, :workflow_not_found}, state}
      {:error, _reason} = error -> mutation_reply(error, state)
    end
  end

  defp validate_workflow_claim(checkpoint, max_active) do
    cond do
      not valid_workflow_checkpoint?(checkpoint) -> {:error, :invalid_workflow_checkpoint}
      not is_integer(max_active) or max_active <= 0 -> {:error, :invalid_workflow_capacity}
      true -> :ok
    end
  end

  defp validate_workflow_identity(current, checkpoint) do
    immutable = [
      :version,
      :remote_execution_id,
      :central_job_id,
      :workflow,
      :idempotency_key,
      :request_fingerprint
    ]

    if Enum.all?(immutable, &(Map.fetch!(current, &1) == Map.fetch!(checkpoint, &1))),
      do: :ok,
      else: {:error, :workflow_identity_changed}
  end

  defp validate_workflow_terminal_transition(current, checkpoint) do
    if terminal_workflow?(current) and current != checkpoint,
      do: {:error, :workflow_terminal},
      else: :ok
  end

  defp persist_workflow_checkpoint(state, checkpoint) do
    persist(
      state.table,
      [{record_key(:workflow_checkpoint, checkpoint.remote_execution_id), record(checkpoint)}],
      state.sync
    )
  end

  defp active_workflow_count(checkpoints) do
    Enum.count(checkpoints, fn {_id, checkpoint} -> not terminal_workflow?(checkpoint) end)
  end

  defp terminal_workflow?(%{status: status}),
    do: status in [:completed, :failed, :cancelled]

  defp terminal_workflow?(_checkpoint), do: false

  defp valid_workflow_checkpoint?(checkpoint) when is_map(checkpoint) do
    required_strings = [
      :remote_execution_id,
      :central_job_id,
      :workflow,
      :idempotency_key,
      :request_fingerprint,
      :runner_generation
    ]

    Map.get(checkpoint, :version) == 1 and
      valid_remote_execution_id?(Map.get(checkpoint, :remote_execution_id)) and
      Enum.all?(required_strings -- [:remote_execution_id], fn key ->
        valid_workflow_id?(Map.get(checkpoint, key))
      end) and
      Map.get(checkpoint, :status) in [
        :accepting,
        :running,
        :intervening,
        :waiting_human,
        :collecting_artifacts,
        :cancelling,
        :orphaned,
        :reconciling,
        :completed,
        :failed,
        :cancelled
      ] and is_atom(Map.get(checkpoint, :phase))
  end

  defp valid_workflow_checkpoint?(_checkpoint), do: false

  defp valid_workflow_id?(value),
    do: is_binary(value) and byte_size(value) in 1..256 and String.valid?(value)

  defp valid_remote_execution_id?(value),
    do: is_binary(value) and Regex.match?(@uuid, value)

  defp valid_event_key?(value),
    do: is_binary(value) and byte_size(value) in 1..256 and String.valid?(value)

  defp map_fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  defp acknowledge_events(state, execution_id, sequence) do
    sequences = Map.get(state.event_unacked, execution_id, MapSet.new())
    acknowledged = Enum.filter(sequences, &(&1 <= sequence))
    keys = Enum.map(acknowledged, &record_key(:event_outbox, {execution_id, &1}))

    case delete_keys(state.table, keys, state.sync) do
      :ok ->
        remaining = Enum.reduce(acknowledged, sequences, &MapSet.delete(&2, &1))

        next = %{
          state
          | event_unacked: Map.put(state.event_unacked, execution_id, remaining),
            event_unacked_count: state.event_unacked_count - length(acknowledged)
        }

        {:reply, :ok, next}

      {:error, _reason} = error ->
        mutation_reply(error, state)
    end
  end

  defp event_append_reply(state, execution_id, event_key, event, deduplicate?) do
    case event_append(state, execution_id, event_key, event, deduplicate?) do
      {:ok, emitted, next} -> {:reply, {:ok, emitted}, next}
      {:replay, emitted} -> {:reply, {:replay, emitted}, state}
      {:error, _reason} = error -> mutation_reply(error, state)
    end
  end

  defp event_append(state, execution_id, event_key, event, deduplicate?) do
    dedup_id = {execution_id, event_key}

    case if(deduplicate?, do: Map.fetch(state.event_dedup, dedup_id), else: :error) do
      {:ok, existing} ->
        if Map.delete(existing, "sequence") == event,
          do: {:replay, existing},
          else: {:error, :event_key_collision}

      :error ->
        append_new_event(state, execution_id, event_key, event, deduplicate?)
    end
  end

  defp append_new_event(state, execution_id, event_key, event, deduplicate?) do
    new_execution? = not Map.has_key?(state.event_sequences, execution_id)

    cond do
      not valid_remote_execution_id?(execution_id) or not is_map(event) ->
        {:error, :invalid_event}

      deduplicate? and not valid_event_key?(event_key) ->
        {:error, :invalid_event_key}

      state.event_unacked_count >= state.max_unacked_events ->
        {:error, :event_capacity_exceeded}

      deduplicate? and map_size(state.event_dedup) >= state.max_unacked_events ->
        {:error, :event_dedup_capacity_exceeded}

      new_execution? and map_size(state.event_sequences) >= state.max_event_executions ->
        {:error, :event_execution_capacity_exceeded}

      true ->
        persist_new_event(state, execution_id, event_key, event, deduplicate?)
    end
  end

  defp persist_new_event(state, execution_id, event_key, event, deduplicate?) do
    sequence = Map.get(state.event_sequences, execution_id, 0) + 1

    sequenced = Map.put(event, "sequence", sequence)

    records = [
      {record_key(:event_sequence, execution_id), record(sequence)},
      {record_key(:event_outbox, {execution_id, sequence}), record(sequenced)}
    ]

    records =
      if deduplicate?,
        do: [{record_key(:event_dedup, {execution_id, event_key}), record(sequenced)} | records],
        else: records

    case persist(state.table, records, state.sync) do
      :ok ->
        sequences = Map.get(state.event_unacked, execution_id, MapSet.new())

        next = %{
          state
          | event_sequences: Map.put(state.event_sequences, execution_id, sequence),
            event_unacked:
              Map.put(state.event_unacked, execution_id, MapSet.put(sequences, sequence)),
            event_unacked_count: state.event_unacked_count + 1,
            event_dedup:
              if(deduplicate?,
                do: Map.put(state.event_dedup, {execution_id, event_key}, sequenced),
                else: state.event_dedup
              )
        }

        {:ok, sequenced, next}

      {:error, _reason} = error ->
        error
    end
  end

  defp reconcile_request_indexes(table, sync) do
    primary = list_namespace(table, :request_dedup)
    expected = Map.new(primary, fn {_request_id, entry} -> {entry.idempotency_key, entry} end)
    existing = list_namespace(table, :request_idempotency)

    stale_keys =
      Enum.flat_map(existing, fn {idempotency_key, entry} ->
        if expected[idempotency_key] == entry,
          do: [],
          else: [record_key(:request_idempotency, idempotency_key)]
      end)

    missing_records =
      Enum.flat_map(expected, fn {idempotency_key, entry} ->
        if Enum.any?(existing, &match?({^idempotency_key, ^entry}, &1)),
          do: [],
          else: [{record_key(:request_idempotency, idempotency_key), record(entry)}]
      end)

    case {stale_keys, missing_records} do
      {[], []} ->
        :ok

      {[], records} ->
        persist(table, records, sync)

      {keys, []} ->
        delete_keys(table, keys, sync)

      {keys, records} ->
        with :ok <- delete_keys(table, keys, sync),
             :ok <- persist(table, records, sync) do
          :ok
        end
    end
  end

  defp initialize_authority_indexes(state) do
    with {:ok, lease_records} <- bounded_namespace_records(state, :profile_lease),
         {:ok, session_records} <- bounded_namespace_records(state, :browser_session) do
      leases =
        Enum.reduce(lease_records, %{}, fn
          {{@format, :profile_lease, profile_id}, %{version: @record_version, value: lease}},
          leases ->
            Map.put(leases, profile_id, lease)

          _invalid, leases ->
            leases
        end)

      {sessions, session_keys} =
        Enum.reduce(session_records, {%{}, %{}}, fn
          {{@format, :browser_session, _session_key} = key,
           %{version: @record_version, value: %{remote_session_id: remote_id}}} = record,
          {sessions, session_keys}
          when is_binary(remote_id) ->
            {Map.put(sessions, key, record), Map.put(session_keys, remote_id, key)}

          _invalid, indexes ->
            indexes
        end)

      {:ok,
       %{
         state
         | profile_leases: leases,
           browser_sessions: sessions,
           browser_session_keys: session_keys
       }}
    end
  end

  defp initialize_workflow_indexes(state) do
    with {:ok, records} <-
           bounded_namespace_records(
             state.table,
             :workflow_checkpoint,
             state.max_workflow_entries
           ),
         {:ok, indexes} <- build_workflow_indexes(records) do
      {:ok,
       %{
         state
         | workflow_checkpoints: indexes.checkpoints,
           workflow_central_index: indexes.central,
           workflow_idempotency_index: indexes.idempotency
       }}
    end
  end

  defp build_workflow_indexes(records) do
    Enum.reduce_while(records, {:ok, %{checkpoints: %{}, central: %{}, idempotency: %{}}}, fn
      {{@format, :workflow_checkpoint, remote_id}, %{version: @record_version, value: checkpoint}},
      {:ok, indexes} ->
        central_id = Map.get(checkpoint, :central_job_id)
        workflow = Map.get(checkpoint, :workflow)
        idempotency_key = Map.get(checkpoint, :idempotency_key)
        key = {workflow, idempotency_key}

        cond do
          not valid_workflow_checkpoint?(checkpoint) or
              checkpoint.remote_execution_id != remote_id ->
            {:halt, {:error, :invalid_workflow_checkpoint}}

          Map.has_key?(indexes.checkpoints, remote_id) or
            Map.has_key?(indexes.central, central_id) or
              Map.has_key?(indexes.idempotency, key) ->
            {:halt, {:error, :workflow_index_collision}}

          true ->
            {:cont,
             {:ok,
              %{
                checkpoints: Map.put(indexes.checkpoints, remote_id, checkpoint),
                central: Map.put(indexes.central, central_id, remote_id),
                idempotency: Map.put(indexes.idempotency, key, remote_id)
              }}}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_workflow_checkpoint}}
    end)
  end

  defp initialize_event_indexes(state) do
    with {:ok, sequence_records} <-
           bounded_namespace_records(state.table, :event_sequence, state.max_event_executions),
         {:ok, emitted_records} <-
           bounded_namespace_records(state.table, :event_emitted, state.max_event_executions),
         {:ok, outbox_records} <-
           bounded_namespace_records(state.table, :event_outbox, state.max_unacked_events),
         {:ok, dedup_records} <-
           bounded_namespace_records(state.table, :event_dedup, state.max_unacked_events),
         {:ok, sequences} <- build_event_sequences(sequence_records),
         {:ok, emitted} <- build_event_emitted(emitted_records, sequences),
         {:ok, unacked} <- build_event_unacked(outbox_records, sequences),
         {:ok, dedup} <- build_event_dedup(dedup_records, sequences) do
      {:ok,
       %{
         state
         | event_sequences: sequences,
           event_emitted: emitted,
           event_unacked: unacked,
           event_unacked_count:
             Enum.reduce(unacked, 0, fn {_id, items}, count -> count + MapSet.size(items) end),
           event_dedup: dedup
       }}
    end
  end

  defp build_event_sequences(records) do
    Enum.reduce_while(records, {:ok, %{}}, fn
      {{@format, :event_sequence, execution_id}, %{version: @record_version, value: sequence}},
      {:ok, acc}
      when is_binary(execution_id) and is_integer(sequence) and sequence >= 0 ->
        {:cont, {:ok, Map.put(acc, execution_id, sequence)}}

      _invalid, _acc ->
        {:halt, {:error, :invalid_event_sequence}}
    end)
  end

  defp build_event_emitted(records, sequences) do
    Enum.reduce_while(records, {:ok, %{}}, fn
      {{@format, :event_emitted, execution_id}, %{version: @record_version, value: sequence}},
      {:ok, acc}
      when is_binary(execution_id) and is_integer(sequence) and sequence > 0 ->
        if Map.get(sequences, execution_id, 0) >= sequence do
          {:cont, {:ok, Map.put(acc, execution_id, sequence)}}
        else
          {:halt, {:error, :invalid_event_emitted}}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_event_emitted}}
    end)
  end

  defp build_event_unacked(records, sequences) do
    Enum.reduce_while(records, {:ok, %{}}, fn
      {{@format, :event_outbox, {execution_id, sequence}},
       %{version: @record_version, value: %{"sequence" => sequence}}},
      {:ok, acc}
      when is_binary(execution_id) and is_integer(sequence) and sequence > 0 ->
        if Map.get(sequences, execution_id, 0) >= sequence do
          set = Map.get(acc, execution_id, MapSet.new())
          {:cont, {:ok, Map.put(acc, execution_id, MapSet.put(set, sequence))}}
        else
          {:halt, {:error, :invalid_event_outbox}}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_event_outbox}}
    end)
  end

  defp build_event_dedup(records, sequences) do
    Enum.reduce_while(records, {:ok, %{}}, fn
      {{@format, :event_dedup, {execution_id, event_key}},
       %{version: @record_version, value: %{"sequence" => sequence} = event}},
      {:ok, acc}
      when is_binary(execution_id) and is_integer(sequence) and sequence > 0 ->
        if Map.get(sequences, execution_id, 0) >= sequence and valid_event_key?(event_key) do
          {:cont, {:ok, Map.put(acc, {execution_id, event_key}, event)}}
        else
          {:halt, {:error, :invalid_event_dedup}}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_event_dedup}}
    end)
  end

  defp initialize_terminal_retention(state) do
    with {:ok, indexes} <- build_terminal_retention(state) do
      state = %{state | terminal_retention: indexes}

      {state, keys} =
        Enum.reduce(@terminal_namespaces, {state, []}, fn namespace, {current, keys} ->
          {index, pruned} =
            current
            |> retention_index(namespace)
            |> prune_retention_index(current, :infinity)

          {
            put_retention_index(current, namespace, index),
            pruned ++ keys
          }
        end)

      case persist_changes(state.table, [], Enum.uniq(keys), state.sync) do
        :ok -> {:ok, state}
        {:error, _reason} = error -> error
      end
    end
  end

  defp build_terminal_retention(state) do
    Enum.reduce_while(@terminal_namespaces, {:ok, %{}}, fn namespace, {:ok, indexes} ->
      case bounded_namespace_records(state, namespace) do
        {:ok, records} ->
          index =
            Enum.reduce(records, empty_retention_index(), fn record, current ->
              add_retention_record(current, state, namespace, record)
            end)

          {:cont, {:ok, Map.put(indexes, namespace, index)}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp put_record(state, :profile_lease, profile_id, lease) do
    old_lease = Map.get(state.profile_leases, profile_id)
    leases = Map.put(state.profile_leases, profile_id, lease)

    with {:ok, state, pruned_keys} <- plan_authority_transition(state, old_lease, lease, leases),
         stored = {record_key(:profile_lease, profile_id), record(lease, state.clock_ms.())},
         :ok <- persist_changes(state.table, [stored], pruned_keys, state.sync) do
      state
      |> Map.put(:profile_leases, leases)
      |> drop_pruned_browser_sessions(pruned_keys)
      |> then(&mutation_reply(:ok, &1))
    else
      {:error, _reason} = error -> mutation_reply(error, state)
    end
  end

  defp put_record(state, namespace, key, value) when namespace in @terminal_namespaces do
    full_key = record_key(namespace, key)
    stored = {full_key, record(value, state.clock_ms.())}
    existing = lookup_record(state.table, full_key)

    with :ok <- validate_terminal_transition(state, namespace, key, existing, value),
         {:ok, index, pruned_keys} <- plan_terminal_put(state, namespace, stored),
         records = if(full_key in pruned_keys, do: [], else: [stored]),
         :ok <- persist_changes(state.table, records, pruned_keys, state.sync) do
      state
      |> put_retention_index(namespace, index)
      |> track_browser_session(namespace, existing, stored, pruned_keys)
      |> then(&mutation_reply(:ok, &1))
    else
      {:error, _reason} = error -> mutation_reply(error, state)
    end
  end

  defp put_record(state, namespace, key, value) do
    result =
      persist(
        state.table,
        [{record_key(namespace, key), record(value, state.clock_ms.())}],
        state.sync
      )

    mutation_reply(result, state)
  end

  defp delete_record(state, :profile_lease, profile_id) do
    old_lease = Map.get(state.profile_leases, profile_id)
    leases = Map.delete(state.profile_leases, profile_id)
    lease_key = record_key(:profile_lease, profile_id)

    with {:ok, state, pruned_keys} <- plan_authority_transition(state, old_lease, nil, leases),
         keys = Enum.uniq([lease_key | pruned_keys]),
         :ok <- persist_changes(state.table, [], keys, state.sync) do
      state
      |> Map.put(:profile_leases, leases)
      |> drop_pruned_browser_sessions(pruned_keys)
      |> then(&mutation_reply(:ok, &1))
    else
      {:error, _reason} = error -> mutation_reply(error, state)
    end
  end

  defp delete_record(state, namespace, key) do
    full_key = record_key(namespace, key)
    existing = lookup_record(state.table, full_key)
    result = delete_keys(state.table, [full_key], state.sync)

    next_state =
      if result == :ok do
        state
        |> drop_terminal_record(namespace, full_key)
        |> untrack_browser_session(namespace, existing)
      else
        state
      end

    mutation_reply(result, next_state)
  end

  defp validate_terminal_transition(state, :pending_action, key, {:ok, {_key, record}}, value) do
    validate_reserved_result_size(state, key, record.value, value)
  end

  defp validate_terminal_transition(
         state,
         :pending_action,
         _key,
         :error,
         %{retention_reserved_bytes: bytes}
       )
       when is_integer(bytes) and bytes > state.terminal_max_bytes,
       do: {:error, :journal_capacity_exceeded}

  defp validate_terminal_transition(_state, _namespace, _key, _existing, _value), do: :ok

  defp plan_terminal_put(state, namespace, stored) do
    index =
      state
      |> retention_index(namespace)
      |> drop_retention_entry(elem(stored, 0))
      |> add_retention_record(state, namespace, stored)

    {index, pruned_keys} = prune_retention_index(index, state, @terminal_prune_batch)

    if retention_within_limits?(index, state),
      do: {:ok, index, pruned_keys},
      else: {:error, :journal_capacity_exceeded}
  end

  defp drop_terminal_record(state, namespace, full_key) when namespace in @terminal_namespaces do
    index = state |> retention_index(namespace) |> drop_retention_entry(full_key)
    put_retention_index(state, namespace, index)
  end

  defp drop_terminal_record(state, _namespace, _full_key), do: state

  defp plan_authority_transition(state, old_lease, new_lease, leases) do
    authority_state = %{state | profile_leases: leases}

    index =
      old_lease
      |> lease_owner_ids()
      |> Kernel.++(lease_owner_ids(new_lease))
      |> Enum.uniq()
      |> Enum.reduce(retention_index(state, :browser_session), fn remote_id, current ->
        with {:ok, key} <- Map.fetch(state.browser_session_keys, remote_id),
             {:ok, record} <- Map.fetch(state.browser_sessions, key) do
          current
          |> drop_retention_entry(key)
          |> add_retention_record(authority_state, :browser_session, record)
        else
          :error -> current
        end
      end)

    {index, pruned_keys} = prune_retention_index(index, authority_state, @terminal_prune_batch)

    if retention_within_limits?(index, authority_state) do
      {:ok, put_retention_index(authority_state, :browser_session, index), pruned_keys}
    else
      {:error, :journal_capacity_exceeded}
    end
  end

  defp lease_owner_ids(%{owner_id: owner_id, suspended: suspended}) do
    [owner_id | lease_owner_ids(suspended)]
  end

  defp lease_owner_ids(%{owner_id: owner_id}), do: [owner_id]
  defp lease_owner_ids(_lease), do: []

  defp track_browser_session(state, :browser_session, existing, stored, pruned_keys) do
    state = untrack_browser_session(state, :browser_session, existing)

    state =
      if elem(stored, 0) in pruned_keys do
        state
      else
        case stored do
          {key, %{value: %{remote_session_id: remote_id}}} when is_binary(remote_id) ->
            %{
              state
              | browser_sessions: Map.put(state.browser_sessions, key, stored),
                browser_session_keys: Map.put(state.browser_session_keys, remote_id, key)
            }

          _invalid ->
            state
        end
      end

    drop_pruned_browser_sessions(state, pruned_keys)
  end

  defp track_browser_session(state, _namespace, _existing, _stored, _pruned_keys), do: state

  defp untrack_browser_session(state, :browser_session, {:ok, {key, record}}) do
    remote_id = get_in(record, [:value, :remote_session_id])

    session_keys =
      if Map.get(state.browser_session_keys, remote_id) == key,
        do: Map.delete(state.browser_session_keys, remote_id),
        else: state.browser_session_keys

    %{
      state
      | browser_sessions: Map.delete(state.browser_sessions, key),
        browser_session_keys: session_keys
    }
  end

  defp untrack_browser_session(state, _namespace, _existing), do: state

  defp drop_pruned_browser_sessions(state, keys) do
    Enum.reduce(keys, state, fn key, current ->
      case Map.get(current.browser_sessions, key) do
        %{value: %{remote_session_id: remote_id}} ->
          %{
            current
            | browser_sessions: Map.delete(current.browser_sessions, key),
              browser_session_keys: Map.delete(current.browser_session_keys, remote_id)
          }

        _missing ->
          current
      end
    end)
  end

  defp empty_retention_index do
    %{
      entries: %{},
      terminal_queue: :gb_sets.empty(),
      terminal_count: 0,
      terminal_bytes: 0,
      reserved_count: 0,
      reserved_bytes: 0
    }
  end

  defp retention_index(state, namespace),
    do: Map.fetch!(state.terminal_retention, namespace)

  defp put_retention_index(state, namespace, index),
    do: %{state | terminal_retention: Map.put(state.terminal_retention, namespace, index)}

  defp add_retention_record(index, state, namespace, record) do
    case retention_entry(state, namespace, record) do
      nil -> index
      entry -> put_retention_entry(index, entry)
    end
  end

  defp retention_entry(state, namespace, {key, _record} = item) do
    cond do
      terminal_record?(state, namespace, item) ->
        %{
          key: key,
          kind: :terminal,
          bytes: record_bytes(item),
          retained_at_ms: retained_at_ms(item),
          order: {retained_at_ms(item), key}
        }

      namespace == :pending_action and reserved_pending_action?(item) ->
        %{key: key, kind: :reserved, bytes: reserved_bytes(item)}

      true ->
        nil
    end
  end

  defp put_retention_entry(index, %{kind: :terminal} = entry) do
    %{
      index
      | entries: Map.put(index.entries, entry.key, entry),
        terminal_queue: :gb_sets.add(entry.order, index.terminal_queue),
        terminal_count: index.terminal_count + 1,
        terminal_bytes: index.terminal_bytes + entry.bytes
    }
  end

  defp put_retention_entry(index, %{kind: :reserved} = entry) do
    %{
      index
      | entries: Map.put(index.entries, entry.key, entry),
        reserved_count: index.reserved_count + 1,
        reserved_bytes: index.reserved_bytes + entry.bytes
    }
  end

  defp drop_retention_entry(index, key) do
    case Map.pop(index.entries, key) do
      {nil, _entries} ->
        index

      {%{kind: :terminal} = entry, entries} ->
        %{
          index
          | entries: entries,
            terminal_queue: :gb_sets.delete_any(entry.order, index.terminal_queue),
            terminal_count: index.terminal_count - 1,
            terminal_bytes: index.terminal_bytes - entry.bytes
        }

      {%{kind: :reserved} = entry, entries} ->
        %{
          index
          | entries: entries,
            reserved_count: index.reserved_count - 1,
            reserved_bytes: index.reserved_bytes - entry.bytes
        }
    end
  end

  defp prune_retention_index(index, state, budget) do
    cutoff = state.clock_ms.() - state.terminal_max_age_ms
    {index, keys, budget} = prune_expired(index, cutoff, budget, [])
    prune_over_limit(index, state, budget, keys)
  end

  defp prune_expired(index, _cutoff, 0, keys), do: {index, keys, 0}

  defp prune_expired(index, cutoff, budget, keys) do
    case oldest_terminal(index) do
      {:ok, %{retained_at_ms: retained_at_ms} = entry} when retained_at_ms <= cutoff ->
        prune_expired(
          drop_retention_entry(index, entry.key),
          cutoff,
          decrement_budget(budget),
          [entry.key | keys]
        )

      _not_expired ->
        {index, keys, budget}
    end
  end

  defp prune_over_limit(index, state, budget, keys) do
    cond do
      retention_within_limits?(index, state) ->
        {index, keys}

      budget == 0 ->
        {index, keys}

      true ->
        case oldest_terminal(index) do
          {:ok, entry} ->
            prune_over_limit(
              drop_retention_entry(index, entry.key),
              state,
              decrement_budget(budget),
              [entry.key | keys]
            )

          :error ->
            {index, keys}
        end
    end
  end

  defp oldest_terminal(%{terminal_queue: queue, entries: entries}) do
    if :gb_sets.is_empty(queue) do
      :error
    else
      {_retained_at_ms, key} = :gb_sets.smallest(queue)
      Map.fetch(entries, key)
    end
  end

  defp retention_within_limits?(index, state) do
    index.terminal_count + index.reserved_count <= state.terminal_max_records and
      index.terminal_bytes + index.reserved_bytes <= state.terminal_max_bytes
  end

  defp retention_visible?(state, namespace, key) when namespace in @terminal_namespaces do
    case Map.get(retention_index(state, namespace).entries, key) do
      %{kind: :terminal, retained_at_ms: retained_at_ms} ->
        retained_at_ms > state.clock_ms.() - state.terminal_max_age_ms

      _nonterminal_or_authoritative ->
        true
    end
  end

  defp retention_visible?(_state, _namespace, _key), do: true

  defp decrement_budget(:infinity), do: :infinity
  defp decrement_budget(budget), do: budget - 1

  defp validate_reserved_result_size(
         state,
         key,
         %{retention_reserved_bytes: reserved_bytes},
         value
       )
       when is_integer(reserved_bytes) and reserved_bytes > 0 do
    if terminal_action_value?(value) do
      actual_bytes =
        record_bytes({record_key(:pending_action, key), record(value, state.clock_ms.())})

      if actual_bytes <= reserved_bytes,
        do: :ok,
        else: {:error, :journal_capacity_exceeded}
    else
      :ok
    end
  end

  defp validate_reserved_result_size(_state, _key, _existing, _value), do: :ok

  defp terminal_action_value?(%{status: status} = value)
       when status in [:completed, :rejected],
       do: Map.get(value, :retryable, false) == false

  defp terminal_action_value?(%{status: :failed} = value),
    do: Map.get(value, :retryable, false) == false

  defp terminal_action_value?(_value), do: false

  defp reserved_pending_action?(
         {{@format, :pending_action, _key}, %{value: %{retention_reserved_bytes: bytes} = value}}
       )
       when is_integer(bytes) and bytes > 0,
       do: not terminal_action_value?(value)

  defp reserved_pending_action?(_record), do: false

  defp reserved_bytes({_key, %{value: %{retention_reserved_bytes: bytes}}}), do: bytes

  defp terminal_record?(
         _state,
         :pending_action,
         {{@format, :pending_action, {_session_id, _action_id}},
          %{value: %{status: status} = value}}
       )
       when status in [:completed, :rejected],
       do: Map.get(value, :retryable, false) == false

  defp terminal_record?(
         _state,
         :pending_action,
         {{@format, :pending_action, {_session_id, _action_id}},
          %{value: %{status: :failed} = value}}
       ),
       do: Map.get(value, :retryable, false) == false

  defp terminal_record?(
         state,
         :browser_session,
         {_key, %{value: %{status: status} = value}}
       )
       when status in [:closed, :failed],
       do:
         Map.get(value, :close_uncertain, false) == false and
           not session_has_lease_authority?(state, value)

  defp terminal_record?(_state, _namespace, _record), do: false

  defp compact_terminal(state, :browser_session, %{status: status} = value)
       when status in [:closed, :failed] do
    if Map.get(value, :close_uncertain, false) or session_has_lease_authority?(state, value) do
      value
    else
      value |> Map.put(:observation, nil) |> Map.delete(:origin_policy)
    end
  end

  defp compact_terminal(_state, _namespace, value), do: value

  defp session_has_lease_authority?(state, %{profile_id: profile_id} = session) do
    session_id = Map.get(session, :remote_session_id)

    case Map.fetch(state.profile_leases, profile_id) do
      {:ok, lease} -> lease_owned_by_session?(lease, session_id)
      :error -> false
    end
  end

  defp session_has_lease_authority?(_state, _session), do: true

  defp lease_owned_by_session?(%{owner_id: owner_id}, session_id) when owner_id == session_id,
    do: true

  defp lease_owned_by_session?(%{suspended: suspended}, session_id) when is_map(suspended),
    do: lease_owned_by_session?(suspended, session_id)

  defp lease_owned_by_session?(_lease, _session_id), do: false

  defp retained_at_ms({_key, %{written_at_ms: written_at_ms}}) when is_integer(written_at_ms),
    do: written_at_ms

  defp retained_at_ms({_key, %{value: %{updated_at: %DateTime{} = updated_at}}}),
    do: DateTime.to_unix(updated_at, :millisecond)

  defp retained_at_ms(_record), do: 0

  defp record_bytes({key, record}), do: :erlang.external_size({key, record})

  defp bounded_recovery_list(state, namespace, opts) do
    statuses = Keyword.fetch!(opts, :statuses)
    session_id = Keyword.get(opts, :session_id)

    match_head = recovery_match_head(namespace, session_id)
    match_spec = [{match_head, [status_guard(statuses)], [:"$_"]}]

    case :dets.select(state.table, match_spec, state.recovery_scan_max_records + 1) do
      :"$end_of_table" ->
        {:ok, []}

      {records, _continuation} when length(records) > state.recovery_scan_max_records ->
        {:error, :recovery_scan_limit_exceeded}

      {records, _continuation} ->
        {:ok, decode_recovery_records(records)}
    end
  end

  defp recovery_match_head(namespace, nil) do
    {
      {@format, namespace, :"$1"},
      %{version: @record_version, value: %{status: :"$2"}}
    }
  end

  defp recovery_match_head(namespace, session_id) do
    {
      {@format, namespace, {session_id, :"$1"}},
      %{version: @record_version, value: %{status: :"$2"}}
    }
  end

  defp status_guard([status | statuses]) do
    Enum.reduce(statuses, {:==, :"$2", status}, fn item, guard ->
      {:orelse, guard, {:==, :"$2", item}}
    end)
  end

  defp decode_recovery_records(records) do
    records
    |> Enum.map(fn
      {{@format, namespace, key}, %{version: @record_version, value: value}}
      when namespace in @terminal_namespaces ->
        {key, value}
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp persist(table, records, sync) do
    with :ok <- insert_records(table, records),
         :ok <- sync.(table) do
      :ok
    else
      {:error, reason} -> {:error, {:journal_write_failed, reason}}
    end
  end

  defp persist_changes(_table, [], [], _sync), do: :ok

  defp persist_changes(table, records, keys, sync) do
    with :ok <- Enum.reduce_while(keys, :ok, &delete_key(table, &1, &2)),
         :ok <- insert_records(table, records),
         :ok <- sync.(table) do
      :ok
    else
      {:error, reason} -> {:error, {:journal_write_failed, reason}}
    end
  end

  defp insert_records(_table, []), do: :ok
  defp insert_records(table, records), do: :dets.insert(table, records)

  defp delete_keys(table, keys, sync) do
    with :ok <- Enum.reduce_while(keys, :ok, &delete_key(table, &1, &2)),
         :ok <- sync.(table) do
      :ok
    else
      {:error, reason} -> {:error, {:journal_write_failed, reason}}
    end
  end

  defp delete_key(table, key, :ok) do
    case :dets.delete(table, key) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp fetch(table, namespace, key) do
    case :dets.lookup(table, record_key(namespace, key)) do
      [{_key, %{version: @record_version, value: value}}] -> {:ok, value}
      [] -> :error
      [_unknown_version] -> :error
    end
  end

  defp lookup_record(table, key) do
    case :dets.lookup(table, key) do
      [{^key, %{version: @record_version}} = record] -> {:ok, record}
      _missing_or_unknown -> :error
    end
  end

  defp list_namespace(table, namespace) do
    table
    |> list_records()
    |> Enum.flat_map(fn
      {{@format, ^namespace, key}, %{version: @record_version, value: value}} -> [{key, value}]
      _other -> []
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp list_visible_namespace(state, namespace) do
    state.table
    |> list_records()
    |> Enum.flat_map(fn
      {{@format, ^namespace, key} = full_key, %{version: @record_version, value: value}} ->
        if retention_visible?(state, namespace, full_key), do: [{key, value}], else: []

      _other ->
        []
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp bounded_namespace_records(state, namespace) do
    limit = state.recovery_scan_max_records + state.terminal_max_records

    match_spec = [
      {{{@format, namespace, :"$1"}, :"$2"}, [], [:"$_"]}
    ]

    case :dets.select(state.table, match_spec, limit + 1) do
      :"$end_of_table" ->
        {:ok, []}

      {records, _continuation} when length(records) > limit ->
        {:error, :recovery_scan_limit_exceeded}

      {records, _continuation} ->
        {:ok, records}
    end
  end

  defp bounded_namespace_records(table, namespace, limit) do
    match_spec = [
      {{{@format, namespace, :"$1"}, :"$2"}, [], [:"$_"]}
    ]

    case :dets.select(table, match_spec, limit + 1) do
      :"$end_of_table" ->
        {:ok, []}

      {records, _continuation} when length(records) > limit ->
        {:error, :recovery_scan_limit_exceeded}

      {records, _continuation} ->
        {:ok, records}
    end
  end

  defp list_records(table) do
    :dets.foldl(fn item, items -> [item | items] end, [], table)
  end

  defp record_key(namespace, key), do: {@format, namespace, key}
  defp record(value), do: %{version: @record_version, value: value}

  defp record(value, written_at_ms),
    do: %{version: @record_version, value: value, written_at_ms: written_at_ms}

  defp generate_generation do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp positive_limit(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> default
    end
  end
end
