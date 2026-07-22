defmodule GSMLG.ProxyRules.CoordinatorTestCompiler do
  def compile(input, options) do
    test_process = Keyword.fetch!(options, :test_process)
    send(test_process, {:compile_started, Keyword.fetch!(options, :generation), self(), input})

    receive do
      {:compile_result, :compile} ->
        GSMLG.ProxyRules.Compiler.compile(
          input,
          Keyword.take(options, [:generation, :compiled_at, :sample_limit])
        )

      {:compile_result, result} ->
        result

      :crash ->
        raise "controlled compiler crash"
    end
  end
end

defmodule GSMLG.ProxyRules.CoordinatorTestStore do
  use Agent

  def start_link(options), do: Agent.start_link(fn -> Keyword.fetch!(options, :state) end)
  def current(server), do: Agent.get(server, & &1.current)
  def metadata(server), do: {:ok, Agent.get(server, & &1.metadata)}

  def stage(server, token, snapshot) do
    test_process = Agent.get(server, & &1.test_process)
    send(test_process, {:stage_started, snapshot.generation, self()})

    receive do
      :finish_stage ->
        Agent.update(
          server,
          &put_in(&1, [:staged, token], %{snapshot: snapshot, status: :staged})
        )

        {:ok, token}

      {:fail_stage, reason} ->
        {:error, reason}
    end
  end

  def commit(server, token) do
    Agent.get_and_update(server, fn state ->
      case {Map.get(state, :fail_commit, false), Map.pop(state.staged, token)} do
        {true, _staged_result} ->
          {{:error, :persistence_failed}, state}

        {false, {nil, _staged}} ->
          {{:error, :invalid_stage}, state}

        {false, {%{snapshot: snapshot, status: :staged}, staged}} ->
          send(state.test_process, {:finalized, snapshot.generation})
          send(state.test_process, {:published, snapshot.generation})

          {:ok,
           %{state | current: {:ok, snapshot}, staged: staged, metadata: %{readiness: :ready}}}
      end
    end)
  end

  def discard(server, token) do
    Agent.update(server, &update_in(&1.staged, fn staged -> Map.delete(staged, token) end))
    :ok
  end

  def update_status(server, readiness, error) do
    Agent.update(server, fn state ->
      current =
        case state.current do
          {:ok, snapshot} -> {:ok, %{snapshot | readiness: readiness, last_error: error}}
          other -> other
        end

      %{state | current: current, metadata: %{readiness: readiness, operational_status: error}}
    end)

    :ok
  end
end

defmodule GSMLG.ProxyRules.CoordinatorTestRemote do
  def snapshot(server), do: Agent.get(server, & &1.snapshot)

  def refresh(server) do
    server |> Agent.get(& &1.test_process) |> send(:refresh_called)
    {:ok, :accepted}
  end
end

defmodule GSMLG.ProxyRules.CoordinatorTestLocal do
  def snapshots(server), do: Agent.get(server, & &1)
end

defmodule GSMLG.ProxyRules.CoordinatorTest do
  use ExUnit.Case, async: false

  alias GSMLG.ProxyRules.{
    Compiler,
    Configuration,
    Coordinator,
    Diagnostic,
    Persistence,
    Snapshot,
    SourceSnapshot,
    Store
  }

  @now ~U[2026-07-23 03:04:05Z]

  setup do
    test_process = self()
    {:ok, remote} = Agent.start_link(fn -> %{snapshot: nil, test_process: test_process} end)
    {:ok, local} = Agent.start_link(fn -> %{proxy: nil, direct: nil} end)

    {:ok, store} =
      GSMLG.ProxyRules.CoordinatorTestStore.start_link(
        state: %{
          current: {:error, :not_ready},
          metadata: %{readiness: :not_ready},
          staged: %{},
          test_process: self()
        }
      )

    name = String.to_atom("coordinator_test_#{System.unique_integer([:positive])}")

    coordinator =
      start_supervised!(
        %{
          id: name,
          start:
            {Coordinator, :start_link,
             [
               [
                 name: name,
                 configuration: configuration(),
                 compiler: GSMLG.ProxyRules.CoordinatorTestCompiler,
                 compiler_options: [test_process: self()],
                 store: {GSMLG.ProxyRules.CoordinatorTestStore, store},
                 remote: {GSMLG.ProxyRules.CoordinatorTestRemote, remote},
                 local: {GSMLG.ProxyRules.CoordinatorTestLocal, local},
                 task_supervisor: GSMLG.ProxyRules.TaskSupervisor,
                 compile_timeout: 500,
                 now: fn -> @now end
               ]
             ]}
        },
        restart: :temporary
      )

    %{coordinator: coordinator, store: store, remote: remote, local: local}
  end

  test "startup queries source snapshots that were ready before registration", context do
    remote = source(:remote, "example.com\n")
    proxy = source(:local_proxy, "proxy.example\n")
    direct = source(:local_direct, "direct.example\n")
    Agent.update(context.remote, &Map.put(&1, :snapshot, remote))
    Agent.update(context.local, fn _ -> %{proxy: proxy, direct: direct} end)

    # Restart so handle_continue observes the pre-existing snapshots.
    :ok = GenServer.stop(context.coordinator)
    coordinator = start_coordinator(context)

    assert_receive {:compile_started, 1, task, _input}
    send(task, {:compile_result, :compile})
    assert_receive {:stage_started, 1, stage_task}, 1_000
    send(stage_task, :finish_stage)
    assert_receive {:published, 1}
    assert {:ok, %Snapshot{generation: 1, readiness: :ready}} = store_current(context.store)
    assert Process.alive?(coordinator)
  end

  test "coalesces rapid changes and never publishes a stale compile or staged result", context do
    send_sources(context.coordinator, "one.example")
    assert_receive {:compile_started, 1, first, _}

    send(
      context.coordinator,
      {:proxy_rules_source, :local_proxy, source(:local_proxy, "two.example\n")}
    )

    send(first, {:compile_result, :compile})
    assert_receive {:stage_started, 1, stale_stage}, 1_000

    send(
      context.coordinator,
      {:proxy_rules_source, :local_proxy, source(:local_proxy, "three.example\n")}
    )

    send(stale_stage, :finish_stage)
    refute_receive {:published, 1}, 30

    assert_receive {:compile_started, 3, latest, %{local_proxy: "three.example\n"}}
    send(latest, {:compile_result, :compile})
    assert_receive {:stage_started, 3, latest_stage}, 1_000
    send(latest_stage, :finish_stage)
    assert_receive {:published, 3}
  end

  test "freshness does not compile and status failures mark the current artifact stale",
       context do
    send_sources(context.coordinator, "one.example")
    assert_receive {:compile_started, 1, task, _}
    send(task, {:compile_result, :compile})
    assert_receive {:stage_started, 1, stage_task}, 1_000
    send(stage_task, :finish_stage)
    assert_receive {:published, 1}

    send(context.coordinator, {:proxy_rules_source_fresh, :remote, %{fetched_at: @now}})
    refute_receive {:compile_started, _, _, _}, 30

    send(context.coordinator, {:proxy_rules_source_status, :remote, :stale, :timeout})

    assert_eventually(fn -> store_current(context.store) end, fn
      {:ok,
       %Snapshot{generation: 1, readiness: :stale, last_error: %{kind: :remote, reason: :timeout}}} ->
        true

      _ ->
        false
    end)

    send(context.coordinator, {:proxy_rules_source_fresh, :remote, %{fetched_at: @now}})
    refute_receive {:compile_started, _, _, _}, 30

    assert_eventually(fn -> store_current(context.store) end, fn
      {:ok, %Snapshot{generation: 1, readiness: :ready, last_error: nil}} -> true
      _ -> false
    end)
  end

  test "manual refresh immediately transitions readiness to refreshing", context do
    assert {:ok, :accepted} = Coordinator.refresh(context.coordinator)
    assert_receive :refresh_called
    assert %{readiness: :refreshing} = Agent.get(context.store, & &1.metadata)
  end

  test "automatic remote fetch status transitions readiness to refreshing", context do
    send(context.coordinator, {:proxy_rules_source_status, :remote, :refreshing, nil})

    assert_eventually(fn -> Agent.get(context.store, & &1.metadata) end, fn
      %{readiness: :refreshing} -> true
      _ -> false
    end)
  end

  test "emits bounded status telemetry for refreshing, stale, and ready transitions", context do
    handler = "coordinator-status-#{System.unique_integer([:positive])}"
    test_process = self()

    :ok =
      :telemetry.attach(
        handler,
        [:gsmlg, :proxy_rules, :status, :change],
        fn _event, measurements, metadata, _config ->
          send(test_process, {:status_change, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, :accepted} = Coordinator.refresh(context.coordinator)
    assert_receive {:status_change, %{generation: 0}, %{readiness: :refreshing}}

    send(context.coordinator, {:proxy_rules_source_status, :remote, :stale, :timeout})
    assert_receive {:status_change, %{generation: 0}, %{readiness: :not_ready}}

    send_sources(context.coordinator, "one.example")
    assert_receive {:compile_started, 1, task, _}
    assert_receive {:status_change, %{generation: 1}, %{readiness: :refreshing}}
    finish_success(task, 1)
    assert_receive {:status_change, %{generation: 1}, %{readiness: :ready}}
  end

  test "an obsolete compile error is discarded without marking the current artifact stale",
       context do
    publish_first(context)

    send(
      context.coordinator,
      {:proxy_rules_source, :local_proxy, source(:local_proxy, "two.example\n")}
    )

    assert_receive {:compile_started, 2, obsolete, _}

    send(
      context.coordinator,
      {:proxy_rules_source, :local_proxy, source(:local_proxy, "three.example\n")}
    )

    send(obsolete, {:compile_result, {:error, []}})
    assert_receive {:compile_started, 3, latest, _}
    assert {:ok, %Snapshot{generation: 1, last_error: nil}} = store_current(context.store)
    finish_success(latest, 3)
  end

  test "obsolete crash and timeout do not overwrite status and start only the latest", context do
    publish_first(context)

    send(
      context.coordinator,
      {:proxy_rules_source, :local_proxy, source(:local_proxy, "two.example\n")}
    )

    assert_receive {:compile_started, 2, crashing, _}

    send(
      context.coordinator,
      {:proxy_rules_source, :local_proxy, source(:local_proxy, "three.example\n")}
    )

    send(crashing, :crash)
    assert_receive {:compile_started, 3, waiting, _}
    assert {:ok, %Snapshot{generation: 1, last_error: nil}} = store_current(context.store)

    send(
      context.coordinator,
      {:proxy_rules_source, :local_proxy, source(:local_proxy, "four.example\n")}
    )

    assert_receive {:compile_started, 4, latest, _}, 1_000
    refute Process.alive?(waiting)
    assert {:ok, %Snapshot{generation: 1, last_error: nil}} = store_current(context.store)
    finish_success(latest, 4)
  end

  test "a source going stale during compilation prevents publication until recovery", context do
    send_sources(context.coordinator, "one.example")
    assert_receive {:compile_started, 1, task, _}
    send(context.coordinator, {:proxy_rules_source_status, :local_proxy, :stale, :not_found})
    send(task, {:compile_result, :compile})
    assert_receive {:stage_started, 1, stage}, 1_000
    send(stage, :finish_stage)
    refute_receive {:published, 1}, 30
    assert {:error, :not_ready} = store_current(context.store)

    send(context.coordinator, {:proxy_rules_source_fresh, :local_proxy, %{observed_at: @now}})
    assert_receive {:compile_started, 1, recovered, _}
    finish_success(recovered, 1)
  end

  test "compile errors, crashes, and timeouts retain the prior artifact", context do
    send_sources(context.coordinator, "one.example")
    assert_receive {:compile_started, 1, first, _}
    send(first, {:compile_result, :compile})
    assert_receive {:stage_started, 1, stage_task}, 1_000
    send(stage_task, :finish_stage)
    assert_receive {:published, 1}

    send(
      context.coordinator,
      {:proxy_rules_source, :local_proxy, source(:local_proxy, "error.example\n")}
    )

    assert_receive {:compile_started, 2, error_task, _}

    diagnostic = %Diagnostic{
      kind: :systemic,
      source: :local_proxy,
      location: :system,
      reason: :systemic_failure,
      sample: nil
    }

    send(error_task, {:compile_result, {:error, [diagnostic]}})
    assert_stale_generation(context.store, 1, :compile_failed)

    send(
      context.coordinator,
      {:proxy_rules_source, :local_proxy, source(:local_proxy, "crash.example\n")}
    )

    assert_receive {:compile_started, 3, crash_task, _}
    send(crash_task, :crash)
    assert_stale_generation(context.store, 1, :task_crash)

    send(
      context.coordinator,
      {:proxy_rules_source, :local_proxy, source(:local_proxy, "timeout.example\n")}
    )

    assert_receive {:compile_started, 4, _timeout_task, _}
    assert_stale_generation(context.store, 1, :compile_timeout)
  end

  test "stage failure retains the prior artifact and refresh delegates safely", context do
    send_sources(context.coordinator, "one.example")
    assert_receive {:compile_started, 1, first, _}
    send(first, {:compile_result, :compile})
    assert_receive {:stage_started, 1, stage_task}, 1_000
    send(stage_task, :finish_stage)
    assert_receive {:published, 1}

    send(
      context.coordinator,
      {:proxy_rules_source, :local_proxy, source(:local_proxy, "two.example\n")}
    )

    assert_receive {:compile_started, 2, second, _}
    send(second, {:compile_result, :compile})
    assert_receive {:stage_started, 2, failed_stage}, 1_000
    send(failed_stage, {:fail_stage, :persistence_failed})
    assert_stale_generation(context.store, 1, :persistence_failed)

    assert {:ok, :accepted} = Coordinator.refresh(context.coordinator)
    assert_receive :refresh_called
  end

  test "matching restored source hashes promote ready without a redundant compile", context do
    remote = source(:remote, "remote.example\n")
    proxy = source(:local_proxy, "proxy.example\n")
    direct = source(:local_direct, "direct.example\n")

    assert {:ok, restored} =
             GSMLG.ProxyRules.Compiler.compile(
               %{
                 remote: Base.encode64(remote.content),
                 local_proxy: proxy.content,
                 local_direct: direct.content
               },
               generation: 7,
               compiled_at: @now,
               sample_limit: 2
             )

    Agent.update(context.store, &%{&1 | current: {:ok, %{restored | readiness: :stale}}})
    Agent.update(context.remote, &Map.put(&1, :snapshot, remote))
    Agent.update(context.local, fn _ -> %{proxy: proxy, direct: direct} end)
    :ok = GenServer.stop(context.coordinator)
    _coordinator = start_coordinator(context)

    refute_receive {:compile_started, _, _, _}, 50
    assert {:ok, %Snapshot{generation: 7, readiness: :ready}} = store_current(context.store)
  end

  test "a restored remote cache cannot promote until a successful reconciliation", context do
    remote = source(:remote, "remote.example\n")
    stale_remote = %{remote | availability: :stale}
    proxy = source(:local_proxy, "proxy.example\n")
    direct = source(:local_direct, "direct.example\n")

    assert {:ok, restored} =
             GSMLG.ProxyRules.Compiler.compile(
               %{
                 remote: Base.encode64(remote.content),
                 local_proxy: proxy.content,
                 local_direct: direct.content
               },
               generation: 7,
               compiled_at: @now,
               sample_limit: 2
             )

    Agent.update(context.store, &%{&1 | current: {:ok, %{restored | readiness: :stale}}})
    Agent.update(context.remote, &Map.put(&1, :snapshot, stale_remote))
    Agent.update(context.local, fn _ -> %{proxy: proxy, direct: direct} end)
    :ok = GenServer.stop(context.coordinator)
    coordinator = start_coordinator(context)

    refute_receive {:compile_started, _, _, _}, 50
    assert {:ok, %Snapshot{generation: 7, readiness: :stale}} = store_current(context.store)

    send(coordinator, {:proxy_rules_source_fresh, :remote, %{fetched_at: @now}})
    refute_receive {:compile_started, _, _, _}, 50
    assert {:ok, %Snapshot{generation: 7, readiness: :ready}} = store_current(context.store)
  end

  test "commit failure retains the prior artifact", context do
    send_sources(context.coordinator, "one.example")
    assert_receive {:compile_started, 1, first, _}
    send(first, {:compile_result, :compile})
    assert_receive {:stage_started, 1, first_stage}, 1_000
    send(first_stage, :finish_stage)
    assert_receive {:published, 1}

    Agent.update(context.store, &Map.put(&1, :fail_commit, true))

    send(
      context.coordinator,
      {:proxy_rules_source, :local_proxy, source(:local_proxy, "two.example\n")}
    )

    assert_receive {:compile_started, 2, second, _}
    send(second, {:compile_result, :compile})
    assert_receive {:stage_started, 2, second_stage}, 1_000
    send(second_stage, :finish_stage)
    assert_stale_generation(context.store, 1, :persistence_failed)
  end

  test "a source change after durable staging cannot survive a store restart", context do
    supervisor = GSMLG.ProxyRules.Supervisor
    directory = Path.join(System.tmp_dir!(), "proxy-rules-authority-#{System.unique_integer()}")
    File.mkdir_p!(directory)

    :ok = Supervisor.terminate_child(supervisor, Coordinator)
    :ok = Supervisor.terminate_child(supervisor, Store)

    on_exit(fn ->
      if Process.whereis(Coordinator), do: GenServer.stop(Coordinator)
      if Process.whereis(Store), do: GenServer.stop(Store)
      _ = Supervisor.restart_child(supervisor, Store)
      _ = Supervisor.restart_child(supervisor, Coordinator)
      File.rm_rf!(directory)
    end)

    {:ok, _store} = Store.start_link(name: Store, state_directory: directory)

    assert {:ok, prior} =
             Compiler.compile(
               %{
                 remote: Base.encode64("||prior-remote.example^\n"),
                 local_proxy: "prior-proxy.example\n",
                 local_direct: "prior-direct.example\n"
               },
               generation: 1,
               compiled_at: @now,
               sample_limit: 2
             )

    assert :ok = Store.publish(prior)
    test_process = self()

    after_stage = fn token ->
      send(test_process, {:durably_staged, self(), token})

      receive do
        :release_staged_result -> :ok
      end
    end

    name = String.to_atom("coordinator_authority_#{System.unique_integer([:positive])}")

    {:ok, coordinator} =
      Coordinator.start_link(
        name: name,
        configuration: %{configuration() | state_directory: directory},
        compiler: GSMLG.ProxyRules.CoordinatorTestCompiler,
        compiler_options: [test_process: self()],
        after_stage: after_stage,
        store: {Store, Store},
        remote: {GSMLG.ProxyRules.CoordinatorTestRemote, context.remote},
        local: {GSMLG.ProxyRules.CoordinatorTestLocal, context.local},
        task_supervisor: GSMLG.ProxyRules.TaskSupervisor,
        compile_timeout: 5_000,
        now: fn -> @now end
      )

    Process.unlink(coordinator)
    send_sources(coordinator, "candidate.example")
    assert_receive {:compile_started, 2, candidate, _}
    send(candidate, {:compile_result, :compile})
    assert_receive {:durably_staged, staged_task, _token}, 2_000

    send(
      coordinator,
      {:proxy_rules_source, :local_proxy, source(:local_proxy, "newer.example\n")}
    )

    assert_eventually(
      fn -> :sys.get_state(coordinator).source_generation end,
      &(&1 == 3)
    )

    send(staged_task, :release_staged_result)
    assert_receive {:compile_started, 3, _latest, _}

    assert {:ok, %Snapshot{generation: 1}} = Store.current()
    assert {:ok, %Snapshot{generation: 1}} = Persistence.read_artifact(directory)

    :ok = GenServer.stop(coordinator)
    :ok = GenServer.stop(Store)
    {:ok, _restarted_store} = Store.start_link(name: Store, state_directory: directory)

    assert {:ok, %Snapshot{generation: 1, readiness: :stale}} = Store.current()
    assert {:ok, %Snapshot{generation: 1}} = Persistence.read_artifact(directory)
  end

  defp start_coordinator(context) do
    name = String.to_atom("coordinator_restart_#{System.unique_integer([:positive])}")

    start_supervised!(
      %{
        id: name,
        start:
          {Coordinator, :start_link,
           [
             [
               name: name,
               configuration: configuration(),
               compiler: GSMLG.ProxyRules.CoordinatorTestCompiler,
               compiler_options: [test_process: self()],
               store: {GSMLG.ProxyRules.CoordinatorTestStore, context.store},
               remote: {GSMLG.ProxyRules.CoordinatorTestRemote, context.remote},
               local: {GSMLG.ProxyRules.CoordinatorTestLocal, context.local},
               task_supervisor: GSMLG.ProxyRules.TaskSupervisor,
               compile_timeout: 500,
               now: fn -> @now end
             ]
           ]}
      },
      restart: :temporary
    )
  end

  defp send_sources(coordinator, local_proxy) do
    send(coordinator, {:proxy_rules_source, :remote, source(:remote, "||remote.example^\n")})

    send(
      coordinator,
      {:proxy_rules_source, :local_proxy, source(:local_proxy, local_proxy <> "\n")}
    )

    send(
      coordinator,
      {:proxy_rules_source, :local_direct, source(:local_direct, "direct.example\n")}
    )
  end

  defp publish_first(context) do
    send_sources(context.coordinator, "one.example")
    assert_receive {:compile_started, 1, first, _}
    finish_success(first, 1)
  end

  defp finish_success(task, generation) do
    send(task, {:compile_result, :compile})
    assert_receive {:stage_started, ^generation, stage}, 1_000
    send(stage, :finish_stage)
    assert_receive {:finalized, ^generation}
    assert_receive {:published, ^generation}
  end

  defp source(kind, content) do
    %SourceSnapshot{
      kind: kind,
      content: content,
      content_sha256: sha256(content),
      observed_at: @now,
      metadata: %{},
      availability: :ready
    }
  end

  defp configuration do
    struct!(Configuration,
      source_url: "https://example.test/gfwlist.txt",
      remote_refresh_interval: 1_000,
      remote_connect_timeout: 11,
      remote_receive_timeout: 12,
      remote_max_body_size: 256,
      retry_min_interval: 10,
      retry_max_interval: 80,
      retry_jitter: false,
      local_proxy_list_path: "proxy.txt",
      local_direct_list_path: "direct.txt",
      local_watch_debounce: 10,
      local_reconciliation_interval: 100,
      state_directory: "/tmp/proxy-rules-coordinator-test",
      cache_control: "public, max-age=60",
      unsupported_rule_sample_limit: 2
    )
  end

  defp store_current(store), do: GSMLG.ProxyRules.CoordinatorTestStore.current(store)

  defp assert_stale_generation(store, generation, reason) do
    assert_eventually(fn -> store_current(store) end, fn
      {:ok, %Snapshot{generation: ^generation, readiness: :stale, last_error: %{reason: ^reason}}} ->
        true

      _ ->
        false
    end)
  end

  defp assert_eventually(fun, predicate) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    do_assert_eventually(fun, predicate, deadline)
  end

  defp do_assert_eventually(fun, predicate, deadline) do
    value = fun.()

    cond do
      predicate.(value) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met: #{inspect(value)}")

      true ->
        Process.sleep(10)
        do_assert_eventually(fun, predicate, deadline)
    end
  end

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
