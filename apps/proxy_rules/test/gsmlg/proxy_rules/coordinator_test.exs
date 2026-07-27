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

  def recover_abandoned(server) do
    Agent.get_and_update(server, fn state ->
      case Map.get(state, :recovery_results, []) do
        [result | rest] ->
          send(state.test_process, {:recovery_attempt, result})
          {result, Map.put(state, :recovery_results, rest)}

        [] ->
          {:ok, state}
      end
    end)
  end

  def source_revision(server), do: Agent.get(server, &Map.get(&1, :source_revision, 0))

  def advance_source_revision(server) do
    Agent.get_and_update(server, fn state ->
      revision = Map.get(state, :source_revision, 0) + 1
      {revision, Map.put(state, :source_revision, revision)}
    end)
  end

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

        {false, {%{snapshot: snapshot, status: :finalized}, staged}} ->
          send(state.test_process, {:published, snapshot.generation})

          {:ok,
           %{state | current: {:ok, snapshot}, staged: staged, metadata: %{readiness: :ready}}}
      end
    end)
  end

  def finalize(server, token) do
    Agent.get_and_update(server, fn state ->
      case Map.fetch(state.staged, token) do
        {:ok, %{snapshot: snapshot, status: :staged} = entry} ->
          send(state.test_process, {:finalized, snapshot.generation})
          {:ok, put_in(state, [:staged, token], %{entry | status: :finalized})}

        _missing_or_finalized ->
          {{:error, :invalid_stage}, state}
      end
    end)
  end

  def commit_if_current(server, token, expected_revision) do
    if source_revision(server) == expected_revision,
      do: commit(server, token),
      else: {:error, :obsolete}
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
  def status(server), do: Agent.get(server, &Map.get(&1, :status))

  def refresh(server) do
    server |> Agent.get(& &1.test_process) |> send(:refresh_called)
    {:ok, :accepted}
  end
end

defmodule GSMLG.ProxyRules.CoordinatorTestLocal do
  def snapshots(server), do: Agent.get(server, & &1)
end

defmodule GSMLG.ProxyRules.CoordinatorTestFileSystem do
  use GenServer

  def start_link(_options), do: GenServer.start_link(__MODULE__, nil)
  def subscribe(_watcher), do: :ok

  @impl true
  def init(nil), do: {:ok, nil}
end

defmodule GSMLG.ProxyRules.CoordinatorIntegrationTransport do
  @behaviour GSMLG.ProxyRules.Transport

  @impl true
  def get(_url, _headers, options) do
    test_process = Keyword.fetch!(options, :test_process)
    send(test_process, {:integration_transport_request, self()})

    receive do
      {:integration_transport_response, response} -> response
    end
  end
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

  test "startup queries a finite remote restore failure missed before registration", context do
    Agent.update(context.remote, &Map.put(&1, :status, {:stale, :no_accepted_rules}))
    :ok = GenServer.stop(context.coordinator)
    coordinator = start_coordinator(context)

    assert_eventually(
      fn -> GSMLG.ProxyRules.CoordinatorTestStore.metadata(context.store) end,
      fn
        {:ok,
         %{
           readiness: :not_ready,
           operational_status: %{kind: :remote, reason: :no_accepted_rules}
         }} ->
          true

        _other ->
          false
      end
    )

    refute_receive {:compile_started, _, _, _}, 50
    assert Process.alive?(coordinator)
  end

  test "successful publication emits bounded aggregate measurements and diagnostic samples",
       context do
    test_process = self()

    events = [
      [:gsmlg, :proxy_rules, :compile, :stop],
      [:gsmlg, :proxy_rules, :artifact, :publication],
      [:gsmlg, :proxy_rules, :diagnostic, :invalid, :sample],
      [:gsmlg, :proxy_rules, :diagnostic, :unsupported, :sample],
      [:gsmlg, :log]
    ]

    handler = {__MODULE__, self(), :publication_telemetry}

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn event, measurements, metadata, pid ->
          send(pid, {:publication_telemetry, event, measurements, metadata})
        end,
        test_process
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    config = %{configuration() | unsupported_rule_sample_limit: 3}
    :ok = GenServer.stop(context.coordinator)
    coordinator = start_coordinator(context, configuration: config)

    remote =
      "||remote.example^\n||bad_domain.example^\n||path.example/path\n"

    local_invalid = String.duplicate("界", 300) <> "_bad"
    send(coordinator, {:proxy_rules_source, :remote, source(:remote, remote)})

    send(
      coordinator,
      {:proxy_rules_source, :local_proxy,
       source(:local_proxy, "proxy.example\n" <> local_invalid <> "\n")}
    )

    send(
      coordinator,
      {:proxy_rules_source, :local_direct, source(:local_direct, "direct.example\n")}
    )

    assert_receive {:compile_started, 1, task, _input}
    finish_success(task, 1)

    assert {:ok, snapshot} = store_current(context.store)
    assert Persistence.valid_snapshot?(snapshot)
    assert Enum.any?(snapshot.diagnostics, &(&1.source == :local_proxy))
    assert Enum.all?(snapshot.diagnostics, &(byte_size(&1.sample) <= 512))
    assert Enum.all?(snapshot.diagnostics, &String.valid?(&1.sample))

    expected = %{
      generation: 1,
      artifact_size:
        snapshot.rendered_outputs
        |> Enum.flat_map(fn {_list, outputs} -> Map.values(outputs) end)
        |> Enum.reduce(0, &(&1.content_length + &2)),
      input_rule_count: 3,
      output_rule_count: 3,
      duplicate_count: 0,
      collapsed_count: 0,
      conflict_count: 0,
      invalid_count: 2,
      unsupported_count: 1
    }

    assert_receive {:publication_telemetry, [:gsmlg, :proxy_rules, :compile, :stop],
                    compile_measurements, %{}}

    assert %{duration: duration} = compile_measurements
    assert duration >= 0
    assert Map.delete(compile_measurements, :duration) == expected

    assert_receive {:publication_telemetry, [:gsmlg, :proxy_rules, :artifact, :publication],
                    ^expected, %{}}

    for diagnostic <- snapshot.diagnostics do
      assert_receive {:publication_telemetry, [:gsmlg, :proxy_rules, :diagnostic, kind, :sample],
                      %{generation: 1}, %{source: source}}

      assert kind == diagnostic.kind
      assert source == diagnostic.source

      assert_receive {:publication_telemetry, [:gsmlg, :log], %{level: :info},
                      %{category: ^kind, source: ^source, sample: sample}}

      assert byte_size(sample) <= 512
      assert String.valid?(sample)
    end
  end

  @tag :tmp_dir
  test "zero-accepted remote replacement preserves the published generation and durable cache",
       %{tmp_dir: dir} = context do
    name = String.to_atom("coordinator_remote_integration_#{System.unique_integer([:positive])}")
    config = %{configuration() | state_directory: dir, remote_max_body_size: 4_096}

    remote =
      start_supervised!(
        %{
          id: {GSMLG.ProxyRules.Source.Remote, name},
          start:
            {GSMLG.ProxyRules.Source.Remote, :start_link,
             [
               [
                 config: config,
                 transport: GSMLG.ProxyRules.CoordinatorIntegrationTransport,
                 transport_options: [test_process: self()],
                 notify: name,
                 task_supervisor: GSMLG.ProxyRules.TaskSupervisor,
                 initial_fetch: false,
                 scheduler: fn _server, _message, _delay -> make_ref() end,
                 cancel_timer: fn _reference -> true end,
                 now: fn -> @now end
               ]
             ]}
        },
        restart: :temporary
      )

    Agent.update(context.local, fn _ ->
      %{
        proxy: source(:local_proxy, "proxy.example\n"),
        direct: source(:local_direct, "direct.example\n")
      }
    end)

    :ok = GenServer.stop(context.coordinator)

    coordinator =
      start_supervised!(
        %{
          id: name,
          start:
            {Coordinator, :start_link,
             [
               [
                 name: name,
                 configuration: config,
                 compiler: GSMLG.ProxyRules.CoordinatorTestCompiler,
                 compiler_options: [test_process: self()],
                 store: {GSMLG.ProxyRules.CoordinatorTestStore, context.store},
                 remote: {GSMLG.ProxyRules.Source.Remote, remote},
                 local: {GSMLG.ProxyRules.CoordinatorTestLocal, context.local},
                 task_supervisor: GSMLG.ProxyRules.TaskSupervisor,
                 compile_timeout: 1_000,
                 now: fn -> @now end
               ]
             ]}
        },
        restart: :temporary
      )

    good_body = Base.encode64("||remote.example^\n")
    assert {:ok, :accepted} = GSMLG.ProxyRules.Source.Remote.refresh(remote)
    assert_receive {:integration_transport_request, fetch}
    send(fetch, {:integration_transport_response, response(200, good_body)})

    assert_receive {:compile_started, 1, compile, _input}, 2_000
    finish_success(compile, 1)
    assert {:ok, published} = store_current(context.store)
    assert {:ok, cached, ^good_body} = Persistence.read_remote_pair(dir)

    zero_accepted_body = Base.encode64("! comments only\n||path.example/path\n")
    assert {:ok, :accepted} = GSMLG.ProxyRules.Source.Remote.refresh(remote)
    assert_receive {:integration_transport_request, rejected_fetch}

    send(
      rejected_fetch,
      {:integration_transport_response, response(200, zero_accepted_body)}
    )

    assert_eventually(
      fn -> store_current(context.store) end,
      fn
        {:ok,
         %Snapshot{
           generation: 1,
           readiness: :stale,
           last_error: %{kind: :remote, reason: :no_accepted_rules}
         }} ->
          true

        _other ->
          false
      end
    )

    assert {:ok, retained} = store_current(context.store)
    assert retained.generation == published.generation
    assert retained.source_versions == published.source_versions
    assert retained.rendered_outputs == published.rendered_outputs
    assert {:ok, ^cached, ^good_body} = Persistence.read_remote_pair(dir)
    refute_receive {:compile_started, 2, _, _}, 50
    assert Process.alive?(coordinator)
  end

  test "reports fixed-label bounded source metadata without bodies or local paths", context do
    remote = %SourceSnapshot{
      kind: :remote,
      content: "remote secret body",
      content_sha256: sha256("remote secret body"),
      observed_at: @now,
      availability: :ready,
      metadata: %{
        source_url: "https://secret.example/gfwlist.txt",
        etag: ~s("remote-etag"),
        last_modified: "Wed, 23 Jul 2026 03:04:05 GMT",
        fetched_at: @now
      }
    }

    local_proxy = %SourceSnapshot{
      kind: :local_proxy,
      content: "proxy secret body",
      content_sha256: sha256("proxy secret body"),
      observed_at: @now,
      availability: :stale,
      metadata: %{path: "/secret/proxy.txt", last_success_at: @now}
    }

    local_direct = %SourceSnapshot{
      kind: :local_direct,
      content: "never valid",
      content_sha256: sha256("never valid"),
      observed_at: @now,
      availability: :stale,
      metadata: %{path: "/secret/direct.txt", last_success_at: nil}
    }

    send(context.coordinator, {:proxy_rules_source, :remote, remote})
    send(context.coordinator, {:proxy_rules_source, :local_proxy, local_proxy})
    send(context.coordinator, {:proxy_rules_source, :local_direct, local_direct})

    assert %{
             remote_gfwlist: %{
               label: "Remote GFWList",
               availability: :ready,
               version: remote_version,
               observed_at: @now,
               last_success_at: @now,
               etag: ~s("remote-etag"),
               last_modified: "Wed, 23 Jul 2026 03:04:05 GMT",
               fetched_at: @now
             },
             local_proxy: %{
               label: "Local proxy list",
               availability: :stale,
               version: local_version,
               observed_at: @now,
               last_success_at: @now
             },
             local_direct: %{
               label: "Local direct list",
               availability: :stale,
               version: direct_version,
               observed_at: @now,
               last_success_at: nil
             }
           } = Coordinator.source_metadata(context.coordinator)

    assert remote_version == remote.content_sha256
    assert local_version == local_proxy.content_sha256
    assert direct_version == local_direct.content_sha256

    metadata = Coordinator.source_metadata(context.coordinator)
    refute inspect(metadata) =~ "secret body"
    refute inspect(metadata) =~ "/secret/proxy.txt"
    refute inspect(metadata) =~ "secret.example"
  end

  @tag :tmp_dir
  test "real local timing updates metadata without compiling or exposing source data",
       %{tmp_dir: dir} = context do
    successful_at = ~U[2026-07-23 03:14:15Z]
    failed_at = ~U[2026-07-23 03:24:25Z]
    proxy_path = Path.join(dir, "private-proxy.txt")
    direct_path = Path.join(dir, "private-direct.txt")
    File.write!(proxy_path, "private.example\n")
    File.write!(direct_path, "")
    {:ok, clock} = Agent.start_link(fn -> @now end)

    config = %{
      configuration()
      | local_proxy_list_path: proxy_path,
        local_direct_list_path: direct_path,
        state_directory: dir
    }

    send(
      context.coordinator,
      {:proxy_rules_source, :remote, source(:remote, "||remote.example^\n")}
    )

    local =
      start_supervised!(
        {GSMLG.ProxyRules.Source.Local,
         [
           config: config,
           notify: context.coordinator,
           file_system: GSMLG.ProxyRules.CoordinatorTestFileSystem,
           scheduler: fn _server, _message, _delay -> make_ref() end,
           cancel_timer: fn _reference -> false end,
           now: fn -> Agent.get(clock, & &1) end
         ]},
        restart: :temporary
      )

    assert_receive {:compile_started, generation, compile, _input}
    finish_success(compile, generation)

    assert_eventually(fn -> Coordinator.source_metadata(context.coordinator) end, fn
      %{local_proxy: %{availability: :ready, last_success_at: @now}} -> true
      _metadata -> false
    end)

    Agent.update(clock, fn _time -> successful_at end)
    assert :ok = GSMLG.ProxyRules.Source.Local.reconcile(local)

    assert_eventually(fn -> Coordinator.source_metadata(context.coordinator) end, fn
      %{
        local_proxy: %{
          availability: :ready,
          observed_at: ^successful_at,
          last_success_at: ^successful_at
        }
      } ->
        true

      _metadata ->
        false
    end)

    refute_receive {:compile_started, _, _, _}, 30

    Agent.update(clock, fn _time -> failed_at end)
    File.rm!(proxy_path)
    assert :ok = GSMLG.ProxyRules.Source.Local.reconcile(local)

    metadata =
      assert_eventually(fn -> Coordinator.source_metadata(context.coordinator) end, fn
        %{
          local_proxy: %{
            availability: :stale,
            observed_at: ^failed_at,
            last_success_at: ^successful_at
          }
        } ->
          true

        _metadata ->
          false
      end)

    refute_receive {:compile_started, _, _, _}, 30
    refute inspect(metadata) =~ proxy_path
    refute inspect(metadata) =~ "private.example"
  end

  test "startup recovery failure stays alive, stale, and operationally blocked", context do
    {:ok, prior} = compiled_snapshot(4, "prior.example")

    Agent.update(context.store, fn state ->
      %{state | current: {:ok, prior}}
      |> Map.put(
        :recovery_results,
        [{:error, :persistence_failed}, {:error, :persistence_failed}]
      )
    end)

    Agent.update(context.remote, &Map.put(&1, :snapshot, source(:remote, "remote.example\n")))

    Agent.update(context.local, fn _ ->
      %{
        proxy: source(:local_proxy, "new.example\n"),
        direct: source(:local_direct, "direct.example\n")
      }
    end)

    handler = "coordinator-recovery-#{System.unique_integer([:positive])}"
    test_process = self()

    :ok =
      :telemetry.attach_many(
        handler,
        [
          [:gsmlg, :proxy_rules, :recovery, :exception],
          [:gsmlg, :proxy_rules, :status, :change]
        ],
        fn event, measurements, metadata, _config ->
          send(test_process, {:recovery_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok = GenServer.stop(context.coordinator)
    scheduler = recovery_scheduler(self())
    coordinator = start_coordinator(context, recovery_scheduler: scheduler)

    assert Process.alive?(coordinator)
    assert_receive {:recovery_attempt, {:error, :persistence_failed}}

    assert_receive {:recovery_telemetry, [:gsmlg, :proxy_rules, :recovery, :exception],
                    %{generation: 4}, %{failure_category: :persistence_failed}}

    assert_receive {:recovery_telemetry, [:gsmlg, :proxy_rules, :status, :change],
                    %{generation: 4}, %{readiness: :stale}}

    assert_receive {:recovery_scheduled, ^coordinator, {:retry_recovery, token}, 10}

    send(coordinator, {:retry_recovery, token})
    assert_receive {:recovery_attempt, {:error, :persistence_failed}}
    assert_receive {:recovery_scheduled, ^coordinator, {:retry_recovery, _next_token}, 20}

    assert {:ok,
            %Snapshot{
              generation: 4,
              readiness: :stale,
              last_error: %{kind: :persistence, reason: :persistence_failed}
            }} = store_current(context.store)

    assert {:error, :not_available} = Coordinator.refresh(coordinator)
    refute_receive :refresh_called, 30
    refute_receive {:compile_started, _, _, _}, 30
  end

  test "successful recovery retry reconciles once and resumes publication", context do
    {:ok, prior} = compiled_snapshot(6, "prior.example")

    Agent.update(context.store, fn state ->
      %{state | current: {:ok, prior}}
      |> Map.put(:recovery_results, [{:error, :persistence_failed}, :ok])
    end)

    Agent.update(context.remote, &Map.put(&1, :snapshot, source(:remote, "remote.example\n")))

    Agent.update(context.local, fn _ ->
      %{
        proxy: source(:local_proxy, "later.example\n"),
        direct: source(:local_direct, "direct.example\n")
      }
    end)

    :ok = GenServer.stop(context.coordinator)
    coordinator = start_coordinator(context, recovery_scheduler: recovery_scheduler(self()))
    assert_receive {:recovery_attempt, {:error, :persistence_failed}}
    assert_receive {:recovery_scheduled, ^coordinator, {:retry_recovery, token}, 10}
    refute_receive {:compile_started, _, _, _}, 30

    send(coordinator, {:retry_recovery, token})
    assert_receive {:recovery_attempt, :ok}
    assert_receive {:compile_started, 7, task, %{local_proxy: "later.example\n"}}
    finish_success(task, 7)
    refute_receive {:compile_started, _, _, _}, 30
    assert {:ok, %Snapshot{generation: 7, readiness: :ready}} = store_current(context.store)
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

  test "an authority revision change without new content retries the same generation", context do
    send_sources(context.coordinator, "one.example")
    assert_receive {:compile_started, 1, first, _}

    send(
      context.coordinator,
      {:proxy_rules_source, :local_proxy, source(:local_proxy, "one.example\n")}
    )

    send(first, {:compile_result, :compile})
    assert_receive {:stage_started, 1, stale_stage}, 1_000
    send(stale_stage, :finish_stage)
    assert_receive {:finalized, 1}
    refute_receive {:published, 1}, 30

    assert_receive {:compile_started, 1, retry, _}
    finish_success(retry, 1)
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

  test "a source change during finalization cannot survive a store restart", context do
    supervisor = GSMLG.ProxyRules.Supervisor
    directory = Path.join(System.tmp_dir!(), "proxy-rules-authority-#{System.unique_integer()}")
    File.mkdir_p!(directory)

    :ok = Supervisor.terminate_child(supervisor, Coordinator)
    :ok = Supervisor.terminate_child(supervisor, Store)

    on_exit(fn ->
      stop_named(Coordinator)
      stop_named(Store)
      _ = Supervisor.restart_child(supervisor, Store)
      _ = Supervisor.restart_child(supervisor, Coordinator)
      File.rm_rf!(directory)
    end)

    _store = start_real_store(name: Store, state_directory: directory)

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
    :ok = GenServer.stop(Store)
    test_process = self()
    root_syncs = :atomics.new(1, [])

    blocking_sync = fn path ->
      if path == directory and :atomics.add_get(root_syncs, 1, 1) == 1 do
        send(test_process, {:finalization_started, self()})

        receive do
          :release_finalization -> :ok
        end
      else
        :ok
      end
    end

    _store =
      start_real_store(
        name: Store,
        state_directory: directory,
        persistence_options: [sync_directory: blocking_sync]
      )

    name = String.to_atom("coordinator_authority_#{System.unique_integer([:positive])}")

    {:ok, coordinator} =
      Coordinator.start_link(
        name: name,
        configuration: %{configuration() | state_directory: directory},
        compiler: GSMLG.ProxyRules.CoordinatorTestCompiler,
        compiler_options: [test_process: self()],
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
    assert_receive {:finalization_started, finalizing_store}, 2_000

    send(
      coordinator,
      {:proxy_rules_source, :local_proxy, source(:local_proxy, "newer.example\n")}
    )

    send(finalizing_store, :release_finalization)
    assert_receive {:compile_started, 3, _latest, _}, 2_000

    assert {:ok, %Snapshot{generation: 1}} = Store.current()
    assert {:ok, %Snapshot{generation: 1}} = Persistence.read_artifact(directory)

    :ok = GenServer.stop(coordinator)
    :ok = GenServer.stop(Store)
    _restarted_store = start_real_store(name: Store, state_directory: directory)

    assert {:ok, %Snapshot{generation: 1, readiness: :stale}} = Store.current()
    assert {:ok, %Snapshot{generation: 1}} = Persistence.read_artifact(directory)
  end

  test "coordinator-only restart rolls back a finalization that was already queued", context do
    supervisor = GSMLG.ProxyRules.Supervisor
    directory = Path.join(System.tmp_dir!(), "proxy-rules-recover-#{System.unique_integer()}")
    File.mkdir_p!(directory)

    :ok = Supervisor.terminate_child(supervisor, Coordinator)
    :ok = Supervisor.terminate_child(supervisor, Store)

    on_exit(fn ->
      stop_named(Coordinator)
      stop_named(Store)
      _ = Supervisor.restart_child(supervisor, Store)
      _ = Supervisor.restart_child(supervisor, Coordinator)
      File.rm_rf!(directory)
    end)

    _store = start_real_store(name: Store, state_directory: directory)

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
    :ok = GenServer.stop(Store)
    test_process = self()
    block_finalization = :atomics.new(1, [])

    blocking_sync = fn path ->
      if path == directory and :atomics.compare_exchange(block_finalization, 1, 0, 1) == :ok do
        send(test_process, {:restart_finalization_started, self()})

        receive do
          :release_restart_finalization -> :ok
        end
      else
        :ok
      end
    end

    _store =
      start_real_store(
        name: Store,
        state_directory: directory,
        persistence_options: [sync_directory: blocking_sync]
      )

    name = String.to_atom("coordinator_recovery_#{System.unique_integer([:positive])}")

    options = [
      name: name,
      configuration: %{configuration() | state_directory: directory},
      compiler: GSMLG.ProxyRules.CoordinatorTestCompiler,
      compiler_options: [test_process: self()],
      store: {Store, Store},
      remote: {GSMLG.ProxyRules.CoordinatorTestRemote, context.remote},
      local: {GSMLG.ProxyRules.CoordinatorTestLocal, context.local},
      task_supervisor: GSMLG.ProxyRules.TaskSupervisor,
      compile_timeout: 5_000,
      now: fn -> @now end
    ]

    {:ok, coordinator} = Coordinator.start_link(options)
    Process.unlink(coordinator)
    send_sources(coordinator, "abandoned.example")
    assert_receive {:compile_started, 2, candidate, _}
    send(candidate, {:compile_result, :compile})
    assert_receive {:restart_finalization_started, finalizing_store}, 2_000
    :ok = GenServer.stop(coordinator)

    restart = Task.async(fn -> Coordinator.start_link(options) end)
    assert nil == Task.yield(restart, 50)
    send(finalizing_store, :release_restart_finalization)
    assert {:ok, restarted} = Task.await(restart, 2_000)
    Process.unlink(restarted)

    send_sources(restarted, "later.example")
    assert_receive {:compile_started, 2, later, _}
    send(later, {:compile_result, :compile})

    assert_eventually(fn -> Store.current() end, fn
      {:ok, %Snapshot{generation: 2}} -> true
      _other -> false
    end)

    assert {:ok, %Snapshot{generation: 2}} = Persistence.read_artifact(directory)
    :ok = GenServer.stop(restarted)
    :ok = GenServer.stop(Store)
    _restarted_store = start_real_store(name: Store, state_directory: directory)
    assert {:ok, %Snapshot{generation: 2, readiness: :stale}} = Store.current()
    assert {:ok, %Snapshot{generation: 2}} = Persistence.read_artifact(directory)
  end

  test "real store retains failed startup recovery until coordinator retry succeeds", context do
    supervisor = GSMLG.ProxyRules.Supervisor

    directory =
      Path.join(System.tmp_dir!(), "proxy-rules-startup-recovery-#{System.unique_integer()}")

    stage_directory = Path.join(directory, ".interrupted-stage")
    File.mkdir_p!(stage_directory)

    :ok = Supervisor.terminate_child(supervisor, Coordinator)
    :ok = Supervisor.terminate_child(supervisor, Store)

    on_exit(fn ->
      stop_named(Coordinator)
      stop_named(Store)
      _ = Supervisor.restart_child(supervisor, Store)
      _ = Supervisor.restart_child(supervisor, Coordinator)
      File.rm_rf!(directory)
    end)

    assert {:ok, prior} = compiled_snapshot(1, "prior-proxy.example")
    assert {:ok, interrupted} = compiled_snapshot(2, "interrupted-proxy.example")
    assert :ok = Persistence.write_artifact(directory, prior)
    assert :ok = Persistence.write_artifact(stage_directory, interrupted)

    assert :ok =
             Persistence.finalize_staged_artifact(
               directory,
               Path.join(stage_directory, "artifact.snapshot"),
               []
             )

    recovery_allowed = :atomics.new(1, [])

    failing_recovery_sync = fn path ->
      if path == directory and :atomics.get(recovery_allowed, 1) == 0,
        do: {:error, :eio},
        else: :ok
    end

    _store =
      start_real_store(
        name: Store,
        state_directory: directory,
        persistence_options: [sync_directory: failing_recovery_sync]
      )

    assert {:ok,
            %Snapshot{
              generation: 1,
              readiness: :stale
            }} = Store.current()

    Agent.update(context.remote, &Map.put(&1, :snapshot, source(:remote, "||remote.example^\n")))

    Agent.update(context.local, fn _ ->
      %{
        proxy: source(:local_proxy, "later.example\n"),
        direct: source(:local_direct, "direct.example\n")
      }
    end)

    name = String.to_atom("coordinator_real_recovery_#{System.unique_integer([:positive])}")

    {:ok, coordinator} =
      Coordinator.start_link(
        name: name,
        configuration: %{configuration() | state_directory: directory},
        compiler: GSMLG.ProxyRules.CoordinatorTestCompiler,
        compiler_options: [test_process: self()],
        store: {Store, Store},
        remote: {GSMLG.ProxyRules.CoordinatorTestRemote, context.remote},
        local: {GSMLG.ProxyRules.CoordinatorTestLocal, context.local},
        task_supervisor: GSMLG.ProxyRules.TaskSupervisor,
        compile_timeout: 5_000,
        recovery_scheduler: recovery_scheduler(self()),
        now: fn -> @now end
      )

    Process.unlink(coordinator)
    assert Process.alive?(coordinator)
    assert_receive {:recovery_scheduled, ^coordinator, {:retry_recovery, token}, 10}
    refute_receive {:compile_started, _, _, _}, 30
    assert {:error, :not_available} = Coordinator.refresh(coordinator)

    assert {:ok,
            %Snapshot{
              generation: 1,
              readiness: :stale,
              last_error: %{kind: :persistence, reason: :persistence_failed}
            }} = Store.current()

    :ok = :atomics.put(recovery_allowed, 1, 1)
    send(coordinator, {:retry_recovery, token})
    assert complete_real_publication(2) >= 1
    refute_receive {:recovery_scheduled, ^coordinator, _, _}, 30

    assert {:ok, %Snapshot{generation: 2}} = Persistence.read_artifact(directory)
    :ok = GenServer.stop(coordinator)
  end

  test "a stale epoch during finalization rejects publication before notification arrives",
       context do
    supervisor = GSMLG.ProxyRules.Supervisor
    directory = Path.join(System.tmp_dir!(), "proxy-rules-stale-epoch-#{System.unique_integer()}")
    File.mkdir_p!(directory)

    :ok = Supervisor.terminate_child(supervisor, Coordinator)
    :ok = Supervisor.terminate_child(supervisor, Store)

    on_exit(fn ->
      stop_named(Coordinator)
      stop_named(Store)
      _ = Supervisor.restart_child(supervisor, Store)
      _ = Supervisor.restart_child(supervisor, Coordinator)
      File.rm_rf!(directory)
    end)

    _store = start_real_store(name: Store, state_directory: directory)

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
    :ok = GenServer.stop(Store)
    test_process = self()
    root_syncs = :atomics.new(1, [])

    blocking_sync = fn path ->
      if path == directory and :atomics.add_get(root_syncs, 1, 1) == 1 do
        send(test_process, {:stale_finalization_started, self()})

        receive do
          :release_stale_finalization -> :ok
        end
      else
        :ok
      end
    end

    _store =
      start_real_store(
        name: Store,
        state_directory: directory,
        persistence_options: [sync_directory: blocking_sync]
      )

    name = String.to_atom("coordinator_stale_epoch_#{System.unique_integer([:positive])}")

    {:ok, coordinator} =
      Coordinator.start_link(
        name: name,
        configuration: %{configuration() | state_directory: directory},
        compiler: GSMLG.ProxyRules.CoordinatorTestCompiler,
        compiler_options: [test_process: self()],
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
    assert_receive {:stale_finalization_started, finalizing_store}, 2_000

    revision = Store.source_revision(Store)
    assert Store.advance_source_revision(Store) > revision
    send(finalizing_store, :release_stale_finalization)
    assert_receive {:compile_started, 2, _retry, _}, 2_000

    send(coordinator, {:proxy_rules_source_status, :local_proxy, :stale, :not_found})
    assert {:ok, %Snapshot{generation: 1}} = Store.current()
    assert {:ok, %Snapshot{generation: 1}} = Persistence.read_artifact(directory)

    :ok = GenServer.stop(coordinator)
    :ok = GenServer.stop(Store)
    _restarted_store = start_real_store(name: Store, state_directory: directory)
    assert {:ok, %Snapshot{generation: 1, readiness: :stale}} = Store.current()
    assert {:ok, %Snapshot{generation: 1}} = Persistence.read_artifact(directory)
  end

  test "store restart cleans a stage orphaned by coordinator termination", context do
    supervisor = GSMLG.ProxyRules.Supervisor
    directory = Path.join(System.tmp_dir!(), "proxy-rules-orphan-#{System.unique_integer()}")
    File.mkdir_p!(directory)

    :ok = Supervisor.terminate_child(supervisor, Coordinator)
    :ok = Supervisor.terminate_child(supervisor, Store)

    on_exit(fn ->
      stop_named(Coordinator)
      stop_named(Store)
      _ = Supervisor.restart_child(supervisor, Store)
      _ = Supervisor.restart_child(supervisor, Coordinator)
      File.rm_rf!(directory)
    end)

    _store = start_real_store(name: Store, state_directory: directory)
    test_process = self()

    after_stage = fn token ->
      send(test_process, {:stage_waiting, token})

      receive do
        :never_release -> :ok
      end
    end

    name = String.to_atom("coordinator_orphan_#{System.unique_integer([:positive])}")

    options = [
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
    ]

    {:ok, coordinator} = Coordinator.start_link(options)
    Process.unlink(coordinator)
    send_sources(coordinator, "candidate.example")
    assert_receive {:compile_started, 1, candidate, _}
    send(candidate, {:compile_result, :compile})
    assert_receive {:stage_waiting, _token}, 2_000
    assert [".artifact-stage-" <> _id] = orphan_stage_entries(directory)

    :ok = GenServer.stop(coordinator)
    :ok = GenServer.stop(Store)
    _restarted_store = start_real_store(name: Store, state_directory: directory)
    assert [] = orphan_stage_entries(directory)

    {:ok, restarted_coordinator} = Coordinator.start_link(options)
    Process.unlink(restarted_coordinator)
    assert Process.alive?(restarted_coordinator)
    :ok = GenServer.stop(restarted_coordinator)
  end

  defp start_coordinator(context, overrides \\ []) do
    name = String.to_atom("coordinator_restart_#{System.unique_integer([:positive])}")

    options =
      Keyword.merge(
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
        ],
        overrides
      )

    start_supervised!(
      %{
        id: name,
        start: {Coordinator, :start_link, [options]}
      },
      restart: :temporary
    )
  end

  defp recovery_scheduler(test_process) do
    fn server, message, delay ->
      send(test_process, {:recovery_scheduled, server, message, delay})
      make_ref()
    end
  end

  defp compiled_snapshot(generation, local_proxy) do
    Compiler.compile(
      %{
        remote: Base.encode64("||remote.example^\n"),
        local_proxy: local_proxy <> "\n",
        local_direct: "direct.example\n"
      },
      generation: generation,
      compiled_at: @now,
      sample_limit: 2
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

  defp complete_real_publication(generation) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    do_complete_real_publication(generation, deadline, 0)
  end

  defp do_complete_real_publication(generation, deadline, attempts) do
    case Store.current() do
      {:ok, %Snapshot{generation: ^generation, readiness: :ready}} ->
        attempts

      _not_published ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("real Store did not publish generation #{generation}")
        else
          receive do
            {:compile_started, ^generation, compile, _input} ->
              send(compile, {:compile_result, :compile})
              do_complete_real_publication(generation, deadline, attempts + 1)
          after
            10 -> do_complete_real_publication(generation, deadline, attempts)
          end
        end
    end
  end

  defp orphan_stage_entries(directory) do
    directory
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, ".artifact-stage-"))
  end

  defp start_real_store(options) do
    {:ok, store} = Store.start_link(options)
    Process.unlink(store)
    store
  end

  defp stop_named(name) do
    GenServer.stop(name)
  catch
    :exit, :noproc -> :ok
    :exit, {:noproc, _call} -> :ok
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

  defp response(status, body), do: {:ok, %{status: status, headers: [], body: body}}

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
