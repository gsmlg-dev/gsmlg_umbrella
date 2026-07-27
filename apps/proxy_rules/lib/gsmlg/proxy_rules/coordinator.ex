defmodule GSMLG.ProxyRules.Coordinator do
  @moduledoc """
  Orders source generations and publishes only the latest complete generation.
  """

  use GenServer

  alias GSMLG.ProxyRules.{Compiler, Configuration, Snapshot, SourceSnapshot, Store, Telemetry}
  alias GSMLG.ProxyRules.Source.{Local, Remote}

  @default_timeout 30_000
  @source_slots [:remote, :local_proxy, :local_direct]

  @type dependency :: {module(), GenServer.server()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    {gen_options, init_options} = Keyword.split(options, [:name])

    GenServer.start_link(
      __MODULE__,
      init_options,
      Keyword.put_new(gen_options, :name, __MODULE__)
    )
  end

  @spec refresh(GenServer.server()) :: {:ok, :accepted} | {:error, :not_available}
  def refresh(server \\ __MODULE__) do
    safe_call(server, :refresh)
  end

  @impl true
  def init(options) do
    with {:ok, config} <- configuration(options),
         {:ok, timeout} <- positive_option(options, :compile_timeout, @default_timeout),
         {:ok, dependencies} <- dependencies(options) do
      current = safe_store_current(dependencies.store)
      generation = restored_generation(current)

      state = %{
        configuration: config,
        compiler: Keyword.get(options, :compiler, Compiler),
        compiler_options: Keyword.get(options, :compiler_options, []),
        after_stage: Keyword.get(options, :after_stage, fn _token -> :ok end),
        store: dependencies.store,
        remote_service: dependencies.remote,
        local_service: dependencies.local,
        task_supervisor: Keyword.get(options, :task_supervisor, GSMLG.ProxyRules.TaskSupervisor),
        compile_timeout: timeout,
        now: Keyword.get(options, :now, &DateTime.utc_now/0),
        recovery_scheduler: Keyword.get(options, :recovery_scheduler, &Process.send_after/3),
        remote: nil,
        local_proxy: nil,
        local_direct: nil,
        source_generation: generation,
        active: nil,
        pending: false,
        last_failure: nil,
        current: current,
        recovery_blocked: false,
        recovery_retry_attempt: 0,
        recovery_timer: nil
      }

      case store_recover_abandoned(dependencies.store) do
        :ok -> {:ok, state, {:continue, :load_sources}}
        _failure -> {:ok, block_on_recovery(state)}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:load_sources, state) do
    state =
      state
      |> put_initial(:remote, safe_remote_snapshot(state.remote_service))
      |> put_initial_locals(safe_local_snapshots(state.local_service))
      |> reconcile_initial()

    state =
      if safe_remote_status(state.remote_service) == :refreshing,
        do: transition(state, :refreshing, nil),
        else: state

    {:noreply, state}
  end

  @impl true
  def handle_call(:refresh, _from, %{recovery_blocked: true} = state),
    do: {:reply, {:error, :not_available}, state}

  def handle_call(:refresh, _from, state) do
    case safe_refresh(state.remote_service) do
      {:ok, :accepted} = accepted -> {:reply, accepted, transition(state, :refreshing, nil)}
      {:error, :not_available} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info(
        {:retry_recovery, token},
        %{recovery_blocked: true, recovery_timer: %{token: token}} = state
      ) do
    state = %{state | recovery_timer: nil}

    case store_recover_abandoned(state.store) do
      :ok ->
        state = %{
          state
          | recovery_blocked: false,
            recovery_retry_attempt: 0,
            last_failure: nil
        }

        state = transition(state, stale_readiness(state), nil)
        {:noreply, state, {:continue, :load_sources}}

      _failure ->
        {:noreply, block_on_recovery(state)}
    end
  end

  def handle_info({:retry_recovery, _stale_token}, state), do: {:noreply, state}

  def handle_info(
        {:proxy_rules_source, kind, %SourceSnapshot{}},
        %{recovery_blocked: true} = state
      )
      when kind in @source_slots,
      do: {:noreply, state}

  def handle_info({:proxy_rules_source_fresh, kind, metadata}, %{recovery_blocked: true} = state)
      when kind in @source_slots and is_map(metadata),
      do: {:noreply, state}

  def handle_info(
        {:proxy_rules_source_status, kind, status, _reason},
        %{recovery_blocked: true} = state
      )
      when kind in @source_slots and status in [:stale, :refreshing],
      do: {:noreply, state}

  def handle_info({:proxy_rules_source, kind, %SourceSnapshot{} = snapshot}, state)
      when kind in @source_slots do
    if snapshot.kind == kind and valid_source?(snapshot) do
      _revision = store_advance_source_revision(state.store)
      {:noreply, accept_source(kind, snapshot, state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:proxy_rules_source_fresh, kind, metadata}, state)
      when kind in @source_slots and is_map(metadata) do
    {:noreply, update_freshness(kind, metadata, state)}
  end

  def handle_info({:proxy_rules_source_status, kind, :stale, reason}, state)
      when kind in @source_slots and is_atom(reason) do
    error = bounded_source_error(kind, reason)
    state = mark_source_stale(kind, state)
    {:noreply, transition(%{state | last_failure: error}, stale_readiness(state), error)}
  end

  def handle_info({:proxy_rules_source_status, :remote, :refreshing, nil}, state),
    do: {:noreply, transition(state, :refreshing, nil)}

  def handle_info({reference, result}, %{active: %{ref: reference} = active} = state) do
    Process.demonitor(reference, [:flush])
    cancel_timer(active.timer)
    {:noreply, complete_task(result, active, %{state | active: nil})}
  end

  def handle_info(
        {:DOWN, reference, :process, _pid, _reason},
        %{active: %{ref: reference} = active} = state
      ) do
    cancel_timer(active.timer)
    state = %{state | active: nil}

    if authoritative?(active.generation, state) do
      _ = store_discard(state.store, active.stage_token)
      {:noreply, fail_generation(:task_crash, state)}
    else
      {:noreply, discard_obsolete(active.stage_token, active.generation, state)}
    end
  end

  def handle_info({:compile_timeout, reference}, %{active: %{ref: reference} = active} = state) do
    _ = Task.Supervisor.terminate_child(state.task_supervisor, active.pid)
    Process.demonitor(reference, [:flush])
    state = %{state | active: nil}

    if authoritative?(active.generation, state) do
      _ = store_discard(state.store, active.stage_token)
      {:noreply, fail_generation(:compile_timeout, state)}
    else
      {:noreply, discard_obsolete(active.stage_token, active.generation, state)}
    end
  end

  def handle_info({_reference, {:ok, token, %Snapshot{}, _started}}, state) do
    _ = store_discard(state.store, token)
    {:noreply, state}
  end

  def handle_info({:compile_timeout, _stale_reference}, state), do: {:noreply, state}
  def handle_info({:DOWN, _reference, :process, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.recovery_timer, do: cancel_timer(state.recovery_timer.ref)

    if state.active do
      cancel_timer(state.active.timer)
      _ = Task.Supervisor.terminate_child(state.task_supervisor, state.active.pid)
    end

    :ok
  end

  defp accept_source(kind, snapshot, state) do
    previous = Map.fetch!(state, kind)
    state = state |> Map.put(kind, snapshot) |> clear_source_failure(kind)

    cond do
      is_nil(previous) and not sources_known?(state) ->
        state

      is_nil(previous) ->
        reconcile_initial(state)

      previous.content_sha256 == snapshot.content_sha256 ->
        state
        |> clear_source_failure(kind)
        |> reconcile_recovered_source()

      true ->
        state
        |> Map.update!(:source_generation, &(&1 + 1))
        |> queue_compile()
    end
  end

  defp reconcile_initial(state) do
    cond do
      not sources_known?(state) ->
        state

      compilable?(state) and restored_matches?(state) ->
        transition(%{state | last_failure: nil}, :ready, nil)

      true ->
        state
        |> Map.update!(:source_generation, &(&1 + 1))
        |> queue_compile()
    end
  end

  defp queue_compile(%{active: nil} = state) do
    if compilable?(state), do: start_compile(state), else: state
  end

  defp queue_compile(state), do: %{state | pending: true}

  defp start_compile(state) do
    generation = state.source_generation
    stage_token = Store.stage_token(generation)
    compiler = state.compiler
    store = state.store
    after_stage = state.after_stage
    authority_revision = store_source_revision(store)
    input = compiler_input(state)

    options =
      [
        generation: generation,
        compiled_at: state.now.(),
        sample_limit: state.configuration.unsupported_rule_sample_limit
      ] ++ state.compiler_options

    started = System.monotonic_time()
    _ = Telemetry.emit([:compile, :start], %{generation: generation}, %{})

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        case safe_compile(compiler, input, options) do
          {:ok, %Snapshot{} = snapshot} ->
            case store_stage(store, stage_token, snapshot) do
              {:ok, token} ->
                :ok = after_stage.(token)

                case store_finalize(store, token) do
                  :ok -> {:ok, token, snapshot, started}
                  {:error, reason} -> {:error, persistence_reason(reason), started}
                end

              {:error, reason} ->
                {:error, persistence_reason(reason), started}
            end

          {:error, _diagnostics} ->
            {:error, :compile_failed, started}

          _invalid ->
            {:error, :compile_failed, started}
        end
      end)

    timer = Process.send_after(self(), {:compile_timeout, task.ref}, state.compile_timeout)
    state = transition(state, :refreshing, nil)

    %{
      state
      | active: %{
          ref: task.ref,
          pid: task.pid,
          generation: generation,
          stage_token: stage_token,
          authority_revision: authority_revision,
          timer: timer
        },
        pending: false
    }
  end

  defp complete_task(result, active, state) do
    if authoritative?(active.generation, state) do
      case result do
        {:ok, _token, %Snapshot{}, _started} ->
          finish_task(result, active, state)

        _failure ->
          _ = store_discard(state.store, active.stage_token)
          finish_task(result, active, state)
      end
    else
      returned_token = result_token(result) || active.stage_token
      discard_obsolete(returned_token, active.generation, state)
    end
  end

  defp finish_task({:ok, token, snapshot, started}, active, state) do
    duration = System.monotonic_time() - started

    if snapshot.generation == active.generation do
      case store_commit_if_current(state.store, token, active.authority_revision) do
        :ok ->
          _ =
            Telemetry.emit(
              [:compile, :stop],
              %{generation: snapshot.generation, duration: duration},
              %{}
            )

          _ = Telemetry.emit([:artifact, :publication], %{generation: snapshot.generation}, %{})

          state
          |> Map.put(:current, {:ok, snapshot})
          |> Map.put(:last_failure, nil)
          |> transition(:ready, nil)
          |> start_pending()

        {:error, :obsolete} ->
          _ = store_discard(state.store, token)
          queue_compile(state)

        {:error, _reason} ->
          _ = store_discard(state.store, token)
          fail_generation(:persistence_failed, state)
      end
    else
      discard_obsolete(token, active.generation, state)
    end
  end

  defp finish_task({:error, reason, _started}, _active, state),
    do: fail_generation(reason, state)

  defp finish_task(_invalid, _active, state),
    do: fail_generation(:compile_failed, state)

  defp fail_generation(reason, state) do
    error = %{kind: failure_kind(reason), reason: reason}

    _ =
      Telemetry.emit([:compile, :exception], %{generation: state.source_generation}, %{
        failure_category: reason
      })

    state
    |> Map.put(:last_failure, error)
    |> transition(stale_readiness(state), error)
    |> start_pending()
  end

  defp start_pending(%{pending: true} = state) do
    if compilable?(state), do: start_compile(%{state | pending: false}), else: state
  end

  defp start_pending(state), do: state

  defp block_on_recovery(state) do
    error = %{kind: :persistence, reason: :persistence_failed}

    _ =
      Telemetry.emit([:recovery, :exception], %{generation: state.source_generation}, %{
        failure_category: :persistence_failed
      })

    state
    |> Map.put(:recovery_blocked, true)
    |> Map.put(:last_failure, error)
    |> transition(stale_readiness(state), error)
    |> schedule_recovery()
  end

  defp schedule_recovery(state) do
    token = make_ref()
    delay = recovery_delay(state.configuration, state.recovery_retry_attempt)
    timer = state.recovery_scheduler.(self(), {:retry_recovery, token}, delay)

    %{
      state
      | recovery_retry_attempt: state.recovery_retry_attempt + 1,
        recovery_timer: %{token: token, ref: timer}
    }
  end

  defp recovery_delay(config, attempt) do
    multiplier = Integer.pow(2, min(attempt, 30))
    min(config.retry_min_interval * multiplier, config.retry_max_interval)
  end

  defp update_freshness(kind, metadata, state) do
    case Map.fetch!(state, kind) do
      %SourceSnapshot{} = snapshot ->
        state =
          Map.put(state, kind, %{
            snapshot
            | metadata: Map.merge(snapshot.metadata, metadata),
              availability: :ready
          })

        state
        |> clear_source_failure(kind)
        |> reconcile_recovered_source()

      nil ->
        state
    end
  end

  defp reconcile_recovered_source(state) do
    cond do
      not compilable?(state) ->
        state

      restored_matches?(state) ->
        transition(%{state | last_failure: nil}, :ready, nil)

      match?(%{generation: generation} when generation == state.source_generation, state.active) ->
        state

      true ->
        queue_compile(state)
    end
  end

  defp mark_source_stale(kind, state) do
    case Map.fetch!(state, kind) do
      %SourceSnapshot{} = snapshot -> Map.put(state, kind, %{snapshot | availability: :stale})
      nil -> state
    end
  end

  defp clear_source_failure(%{last_failure: %{kind: failure_kind}} = state, kind)
       when failure_kind == kind,
       do: %{state | last_failure: nil}

  defp clear_source_failure(state, _kind), do: state

  defp transition(state, requested_readiness, error) do
    readiness = resulting_readiness(state, requested_readiness)
    _ = store_update_status(state.store, readiness, error)

    _ =
      Telemetry.emit([:status, :change], %{generation: state.source_generation}, %{
        readiness: readiness
      })

    current =
      case state.current do
        {:ok, snapshot} -> {:ok, %{snapshot | readiness: readiness, last_error: error}}
        unavailable -> unavailable
      end

    %{state | current: current}
  end

  defp resulting_readiness(%{current: {:ok, _snapshot}}, readiness), do: readiness
  defp resulting_readiness(_state, :refreshing), do: :refreshing
  defp resulting_readiness(_state, _readiness), do: :not_ready

  defp authoritative?(generation, state),
    do: generation == state.source_generation and compilable?(state)

  defp discard_obsolete(token, generation, state) do
    _ = store_discard(state.store, token)
    _ = Telemetry.emit([:compile, :stale_result, :discard], %{generation: generation}, %{})
    start_pending(state)
  end

  defp result_token({:ok, token, %Snapshot{}, _started}), do: token
  defp result_token(_result), do: nil

  defp compiler_input(state) do
    %{
      remote: Base.encode64(state.remote.content),
      local_proxy: state.local_proxy.content,
      local_direct: state.local_direct.content
    }
  end

  defp sources_known?(state),
    do: Enum.all?(@source_slots, &match?(%SourceSnapshot{}, Map.fetch!(state, &1)))

  defp compilable?(state) do
    sources_known?(state) and state.remote.availability == :ready and
      state.local_proxy.availability in [:ready, :missing] and
      state.local_direct.availability in [:ready, :missing]
  end

  defp restored_matches?(%{current: {:ok, %Snapshot{} = snapshot}} = state) do
    snapshot.source_versions == %{
      gfwlist: state.remote.content_sha256,
      local_proxy: state.local_proxy.content_sha256,
      local_direct: state.local_direct.content_sha256
    }
  end

  defp restored_matches?(_state), do: false

  defp put_initial(state, _kind, nil), do: state
  defp put_initial(state, kind, %SourceSnapshot{} = snapshot), do: Map.put(state, kind, snapshot)

  defp put_initial_locals(state, %{proxy: proxy, direct: direct}) do
    state |> put_initial(:local_proxy, proxy) |> put_initial(:local_direct, direct)
  end

  defp put_initial_locals(state, _invalid), do: state

  defp valid_source?(snapshot) do
    is_binary(snapshot.content) and String.valid?(snapshot.content) and
      is_binary(snapshot.content_sha256) and byte_size(snapshot.content_sha256) == 64 and
      SourceSnapshot.valid_availability?(snapshot.availability)
  end

  defp configuration(options) do
    case Keyword.fetch(options, :configuration) do
      {:ok, %Configuration{} = config} -> {:ok, config}
      {:ok, _invalid} -> {:error, {:invalid_option, :configuration}}
      :error -> Configuration.load()
    end
  end

  defp dependencies(options) do
    dependencies = %{
      store: Keyword.get(options, :store, {Store, Store}),
      remote: Keyword.get(options, :remote, {Remote, Remote}),
      local: Keyword.get(options, :local, {Local, Local})
    }

    if Enum.all?(dependencies, fn {_key, value} -> valid_dependency?(value) end),
      do: {:ok, dependencies},
      else: {:error, {:invalid_option, :dependency}}
  end

  defp valid_dependency?({module, server}) when is_atom(module), do: not is_nil(server)
  defp valid_dependency?(_dependency), do: false

  defp positive_option(options, key, default) do
    case Keyword.get(options, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _invalid -> {:error, {:invalid_option, key}}
    end
  end

  defp safe_compile(module, input, options), do: module.compile(input, options)

  defp safe_remote_snapshot({module, server}), do: safe_apply(module, :snapshot, [server], nil)
  defp safe_remote_status({module, server}), do: safe_apply(module, :status, [server], nil)
  defp safe_local_snapshots({module, server}), do: safe_apply(module, :snapshots, [server], %{})

  defp safe_refresh({module, server}),
    do: safe_apply(module, :refresh, [server], {:error, :not_available})

  defp safe_store_current({module, server}),
    do: safe_apply(module, :current, [server], {:error, :not_ready})

  defp store_recover_abandoned({module, server}),
    do: safe_apply(module, :recover_abandoned, [server], {:error, :persistence_failed})

  defp store_stage({module, server}, token, snapshot),
    do: safe_apply(module, :stage, [server, token, snapshot], {:error, :persistence_failed})

  defp store_finalize({module, server}, token),
    do: safe_apply(module, :finalize, [server, token], {:error, :persistence_failed})

  defp store_source_revision({module, server}),
    do: safe_apply(module, :source_revision, [server], 0)

  defp store_advance_source_revision({module, server}),
    do: safe_apply(module, :advance_source_revision, [server], 0)

  defp store_commit_if_current({module, server}, token, revision),
    do:
      safe_apply(
        module,
        :commit_if_current,
        [server, token, revision],
        {:error, :persistence_failed}
      )

  defp store_discard({module, server}, token),
    do: safe_apply(module, :discard, [server, token], :ok)

  defp store_update_status({module, server}, readiness, error),
    do: safe_apply(module, :update_status, [server, readiness, error], {:error, :not_available})

  defp safe_apply(module, function, arguments, fallback) do
    apply(module, function, arguments)
  rescue
    _error -> fallback
  catch
    :exit, _reason -> fallback
    _kind, _reason -> fallback
  end

  defp safe_call(server, request) do
    GenServer.call(server, request)
  catch
    :exit, _reason -> {:error, :not_available}
  end

  defp restored_generation({:ok, %Snapshot{generation: generation}}), do: generation
  defp restored_generation(_current), do: 0

  defp stale_readiness(%{current: {:ok, _snapshot}}), do: :stale
  defp stale_readiness(_state), do: :not_ready
  defp failure_kind(:persistence_failed), do: :persistence
  defp failure_kind(_reason), do: :compiler
  defp persistence_reason(:invalid_snapshot), do: :persistence_failed
  defp persistence_reason(_reason), do: :persistence_failed

  defp bounded_source_error(kind, reason) do
    error = %{kind: source_error_kind(kind), reason: reason}

    if Snapshot.valid_operational_error?(error),
      do: error,
      else: %{kind: source_error_kind(kind), reason: :source_unavailable}
  end

  defp source_error_kind(:remote), do: :remote
  defp source_error_kind(kind), do: kind
  defp cancel_timer(nil), do: :ok
  defp cancel_timer(reference), do: Process.cancel_timer(reference)
end
