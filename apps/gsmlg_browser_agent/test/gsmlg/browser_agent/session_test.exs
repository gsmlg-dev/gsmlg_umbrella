defmodule GSMLG.BrowserAgent.SessionTest do
  use ExUnit.Case, async: true

  alias GSMLG.BrowserAgent.{
    Backend.ControlConnection,
    Capability,
    Journal,
    ProfileLeaseServer,
    RequestDedup,
    SafeBrowser,
    Session,
    SessionSupervisor,
    Settings
  }

  alias GSMLG.Commander.CapabilityRegistry
  alias GSMLG.Commander.Protocol.RPCRequest

  @artifact_job_id "00000000-0000-4000-8000-000000000201"

  defmodule Adapter do
    @behaviour GSMLG.BrowserAgent.SafeBrowser.Adapter

    @impl true
    def observe(agent, _timeout) do
      Agent.get_and_update(agent, fn
        %{observations: [next | rest]} = state ->
          {{:ok, next}, %{state | observations: rest}}

        state ->
          case state.fallback_observation do
            %{} = fallback -> {{:ok, fallback}, state}
            nil -> {{:error, :cdp_disconnected}, state}
          end
      end)
    end

    @impl true
    def execute(agent, action, target, _timeout) do
      Agent.get_and_update(agent, fn state ->
        result = Map.get(state, :action_result, {:ok, %{}})
        {result, update_in(state.executions, fn items -> [{action.type, target} | items] end)}
      end)
    end
  end

  defmodule Backend do
    @behaviour GSMLG.BrowserAgent.Backend

    def manager_status(_settings, _opts), do: {:ok, %{}}
    def list_profiles(_settings, _opts), do: {:ok, []}
    def get_profile(_settings, profile_id, _opts), do: {:ok, %{"id" => profile_id}}

    def profile_status(_settings, _profile_id, opts) do
      case opts[:state_agent] do
        agent when is_pid(agent) -> Agent.get(agent, & &1.profile_status_result)
        _none -> {:ok, %{"status" => "running"}}
      end
    end

    def launch_profile(_settings, profile_id, _opts), do: {:ok, %{"profile_id" => profile_id}}
    def stop_profile(_settings, profile_id, _opts), do: {:ok, %{"profile_id" => profile_id}}

    def open_session(_settings, profile_id, opts) do
      send(opts[:test_pid], {:backend_open, profile_id})
      {:ok, %{"profile_id" => profile_id}}
    end

    def connect_control_protocol(_settings, %{"profile_id" => profile_id}, _opts) do
      {:ok,
       %ControlConnection{
         url: "ws://127.0.0.1:8080/api/profiles/#{profile_id}/cdp",
         headers: [{"authorization", "Bearer redacted"}]
       }}
    end

    def close_session(_settings, session, opts) do
      send(opts[:test_pid], {:backend_close, session["profile_id"]})
      {:ok, %{"status" => "closed"}}
    end
  end

  defmodule Transport do
    @behaviour GSMLG.BrowserAgent.CDP.Transport

    def connect(url, _headers, owner, opts) do
      socket = %{owner: owner, test_pid: opts[:test_pid], url: url, ref: make_ref()}
      Kernel.send(socket.test_pid, {:transport_open, socket})
      Kernel.send(owner, {:cdp_transport, socket, :open})
      {:ok, socket}
    end

    def send(socket, payload) do
      %{"id" => id, "method" => method} = JSON.decode!(payload)
      result = result(method)

      Kernel.send(
        socket.owner,
        {:cdp_transport, socket, {:text, JSON.encode!(%{"id" => id, "result" => result})}}
      )

      :ok
    end

    def close(socket) do
      Kernel.send(socket.test_pid, {:transport_closed, socket.ref})
      :ok
    end

    defp result("Page.getNavigationHistory") do
      %{
        "currentIndex" => 0,
        "entries" => [%{"url" => "https://gemini.google.com/app", "title" => "Recovered"}]
      }
    end

    defp result("Accessibility.getFullAXTree"), do: %{"nodes" => []}
    defp result(_method), do: %{}
  end

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    suffix = System.unique_integer([:positive])
    dets_name = String.to_atom("session_journal_#{suffix}")
    registry_name = String.to_atom("session_registry_#{suffix}")
    runner_supervisor_name = String.to_atom("session_runners_#{suffix}")
    cdp_supervisor_name = String.to_atom("session_cdp_#{suffix}")

    settings =
      Settings.load!(
        %{
          enabled: true,
          manager_url: "http://127.0.0.1:8080",
          manager_token_env: "IGNORED",
          state_dir: tmp_dir,
          max_concurrent_sessions: 1,
          security: %{
            allowed_origins: ["https://gemini.google.com"],
            allowed_upload_origins: ["https://uploads.example.test"]
          }
        },
        manager_token: "secret"
      )

    {:ok, journal} =
      Journal.start_link(
        name: nil,
        path: Path.join(tmp_dir, "sessions.dets"),
        dets_name: dets_name
      )

    {:ok, leases} = ProfileLeaseServer.start_link(name: nil, journal: journal)

    {:ok, adapter_state} =
      Agent.start_link(fn ->
        %{
          observations: [],
          executions: [],
          factory_result: :ok,
          action_result: {:ok, %{}},
          close_results: [],
          profile_status_result: {:ok, %{"status" => "running"}},
          fallback_observation: observation("Opened")
        }
      end)

    factory = fn opts ->
      case Agent.get(adapter_state, & &1.factory_result) do
        :ok ->
          SafeBrowser.new(
            session_id: opts[:session_id],
            central_session_id: opts[:central_session_id],
            profile_id: opts[:profile_id],
            lease_id: opts[:lease_id],
            journal: journal,
            lease_server: leases,
            client: adapter_state,
            adapter: Adapter,
            origin_policy: opts[:origin_policy],
            resolver: fn _ -> {:ok, [{8, 8, 8, 8}]} end,
            clock: fn -> DateTime.utc_now() end,
            revision: opts[:revision],
            observation: opts[:observation],
            state_dir: tmp_dir,
            allow_css_locator: opts[:allow_css_locator],
            allow_screenshots: true,
            allow_downloads: true,
            max_observation_nodes: 100,
            max_observation_depth: 8,
            max_observation_bytes: 32_000,
            artifact_job_id: opts[:artifact_job_id],
            artifact_remote_execution_id: opts[:artifact_remote_execution_id]
          )

        :error ->
          {:error, :factory_failed}
      end
    end

    closer = fn _browser, _session ->
      Agent.get_and_update(adapter_state, fn
        %{close_results: [next | rest]} = state -> {next, %{state | close_results: rest}}
        state -> {:ok, state}
      end)
    end

    {:ok, supervisor} =
      SessionSupervisor.start_link(
        name: nil,
        registry_name: registry_name,
        runner_supervisor_name: runner_supervisor_name,
        cdp_supervisor_name: cdp_supervisor_name,
        journal: journal,
        lease_server: leases,
        settings: settings,
        browser_factory: factory,
        browser_closer: closer,
        backend: Backend,
        backend_opts: [state_agent: adapter_state, test_pid: self()],
        id_generator: fn -> "session-1" end
      )

    on_exit(fn ->
      safe_stop(supervisor, &Supervisor.stop/1)
      safe_stop(adapter_state, &Agent.stop/1)
      safe_stop(leases, &GenServer.stop/1)
      safe_stop(journal, &GenServer.stop/1)
      _ = :dets.close(dets_name)
    end)

    %{
      supervisor: supervisor,
      journal: journal,
      leases: leases,
      settings: settings,
      adapter_state: adapter_state
    }
  end

  test "opens, observes, acts, hands off manually, resumes with a fresh observation, and closes",
       context do
    assert {:ok,
            %{
              "central_session_id" => "central-1",
              "remote_session_id" => "session-1",
              "status" => "ready",
              "revision" => 1,
              "lease_id" => lease_id,
              "expires_at" => expires_at
            }} = Session.open(context.supervisor, open_params())

    assert {:ok, _date, _offset} = DateTime.from_iso8601(expires_at)

    enqueue(context.adapter_state, [observation("Initial")])
    assert {:ok, %{"revision" => 2}} = Session.observe(context.supervisor, "session-1")

    enqueue(context.adapter_state, [observation("After click")])

    assert {:ok, %{"revision" => 3}} =
             Session.act(
               context.supervisor,
               "session-1",
               action("action-1", 2)
             )

    assert {:ok, %{"status" => "waiting_human", "lease_id" => manual_lease}} =
             Session.manual_handoff(context.supervisor, "session-1", "operator-1")

    refute manual_lease == lease_id

    assert {:error, :session_not_ready} =
             Session.act(context.supervisor, "session-1", action("action-2", 3))

    enqueue(context.adapter_state, [observation("After manual")])

    assert {:ok, %{"status" => "ready", "revision" => 4, "lease_id" => resumed_lease}} =
             Session.resume_automation(context.supervisor, "session-1")

    refute resumed_lease == manual_lease
    assert {:ok, %{"status" => "closed"}} = Session.close(context.supervisor, "session-1")
    assert :error = ProfileLeaseServer.get(context.leases, "profile-1")

    assert {:ok, %{"status" => "closed"}} = Session.close(context.supervisor, "session-1")
    assert nil == SessionSupervisor.runner(context.supervisor, "session-1")

    assert {:ok, %{status: :closed, revision: 4}} =
             Journal.get(context.journal, :browser_session, "session-1")
  end

  test "opens an actor-bound manual session without granting automation authority", context do
    params =
      open_params()
      |> Map.put("mode", "manual")
      |> Map.put("operator_id", "operator-1")

    assert {:ok,
            %{
              "mode" => "manual",
              "status" => "waiting_human",
              "lease_id" => lease_id,
              "lease_owner_type" => "manual",
              "lease_owner_id" => "operator-1"
            } = first} = Session.open(context.supervisor, params)

    assert {:ok, lease} = ProfileLeaseServer.get(context.leases, "profile-1")
    assert lease.lease_id == lease_id
    assert lease.owner_type == :manual
    assert lease.owner_id == "operator-1"
    assert lease.mode == :manual

    assert {:error, :session_not_ready} = Session.observe(context.supervisor, "session-1")

    assert {:error, :session_not_ready} =
             Session.act(context.supervisor, "session-1", action("blocked", 0))

    assert {:ok, ^first} = Session.open(context.supervisor, params)

    assert {:error, :central_session_id_collision} =
             Session.open(context.supervisor, %{params | "operator_id" => "operator-2"})

    runner = SessionSupervisor.runner(context.supervisor, "session-1")
    Process.exit(runner, :kill)

    assert eventually(fn ->
             match?(
               {:ok,
                %{
                  "status" => "waiting_human",
                  "lease_owner_type" => "manual",
                  "lease_owner_id" => "operator-1"
                }},
               Session.reconcile(context.supervisor, "session-1")
             )
           end)
  end

  test "manual acquire/release is identity-bound, durable, idempotent, and remains paused",
       context do
    assert {:ok, %{"status" => "ready"}} = Session.open(context.supervisor, open_params())

    assert {:ok, %{"status" => "waiting_human", "lease_id" => manual_lease}} =
             Session.manual_acquire(context.supervisor, "session-1", "operator-1")

    assert {:ok,
            %{
              "status" => "waiting_human",
              "lease_id" => ^manual_lease,
              "lease_owner_type" => "manual",
              "lease_owner_id" => "operator-1"
            }} = Session.manual_acquire(context.supervisor, "session-1", "operator-1")

    assert {:error, :operator_identity_mismatch} =
             Session.manual_acquire(context.supervisor, "session-1", "operator-2")

    assert {:error, :operator_identity_mismatch} =
             Session.manual_release(
               context.supervisor,
               "session-1",
               manual_lease,
               "operator-2"
             )

    assert {:ok,
            %{
              "status" => "waiting_human",
              "lease_id" => nil,
              "lease_owner_type" => "released",
              "lease_owner_id" => "operator-1"
            }} =
             Session.manual_release(
               context.supervisor,
               "session-1",
               manual_lease,
               "operator-1"
             )

    assert :error = ProfileLeaseServer.get(context.leases, "profile-1")

    assert {:ok, %{"status" => "waiting_human", "lease_id" => nil}} =
             Session.manual_release(
               context.supervisor,
               "session-1",
               manual_lease,
               "operator-1"
             )

    assert {:error, :session_not_ready} =
             Session.act(context.supervisor, "session-1", action("blocked", 1))

    assert {:ok, %{"status" => "waiting_human", "lease_id" => reacquired_manual_lease}} =
             Session.manual_acquire(context.supervisor, "session-1", "operator-1")

    refute reacquired_manual_lease == manual_lease

    enqueue(context.adapter_state, [observation("After released manual lease")])

    assert {:ok, %{"status" => "ready", "revision" => 2, "lease_id" => resumed_lease}} =
             Session.resume_automation(context.supervisor, "session-1")

    refute resumed_lease == manual_lease
    refute resumed_lease == reacquired_manual_lease

    assert {:ok, lease} = ProfileLeaseServer.get(context.leases, "profile-1")
    assert lease.owner_type == :automation
    assert lease.owner_id == "session-1"
  end

  test "a released manual session closes without an active lease", context do
    assert {:ok, %{"status" => "ready"}} = Session.open(context.supervisor, open_params())

    assert {:ok, %{"lease_id" => manual_lease}} =
             Session.manual_acquire(context.supervisor, "session-1", "operator-1")

    assert {:ok, %{"status" => "waiting_human", "lease_id" => nil}} =
             Session.manual_release(
               context.supervisor,
               "session-1",
               manual_lease,
               "operator-1"
             )

    assert {:ok, %{"status" => "closed"}} = Session.close(context.supervisor, "session-1")
    assert :error = ProfileLeaseServer.get(context.leases, "profile-1")
  end

  test "workflow screenshots are durably attributed to the central job and execution", context do
    execution_id = "00000000-0000-4000-8000-000000000001"

    assert {:ok, %{"status" => "ready", "revision" => 1}} =
             SessionSupervisor.open_workflow(context.supervisor, %{
               "central_session_id" => execution_id,
               "remote_execution_id" => execution_id,
               "artifact_job_id" => @artifact_job_id,
               "profile_id" => "profile-1",
               "mode" => "workflow",
               "authorized_origins" => ["https://gemini.google.com"],
               "required_profile_capabilities" => ["gemini_authenticated"],
               "ttl_ms" => 60_000,
               "permissions" => %{"screenshot" => true, "download" => false}
             })

    enqueue(context.adapter_state, [observation("Captured")])

    Agent.update(
      context.adapter_state,
      &Map.put(&1, :action_result, {:ok, {:artifact, "screenshot", "image/png", "png"}})
    )

    assert {:ok, %{"output" => %{"artifact" => manifest}}} =
             Session.act(context.supervisor, execution_id, %{
               "action_id" => "workflow-screenshot",
               "session_id" => execution_id,
               "expected_revision" => 1,
               "type" => "screenshot",
               "timeout_ms" => 5_000,
               "preconditions" => [],
               "postconditions" => []
             })

    assert manifest["artifact_id"] ==
             GSMLG.BrowserAgent.WorkflowArtifacts.artifact_id(execution_id, "screenshot.png")

    assert manifest["job_id"] == @artifact_job_id
    assert manifest["kind"] == "screenshot.png"
    assert manifest["filename"] == "report.png"
    assert manifest["metadata"] == %{"remote_execution_id" => execution_id}
  end

  test "open authorizes an initial observation and observe returns its bounded structure",
       context do
    enqueue(context.adapter_state, [observation("Opened")])

    assert {:ok, %{"status" => "ready", "revision" => 1}} =
             Session.open(context.supervisor, open_params())

    enqueue(context.adapter_state, [observation("Observed")])

    assert {:ok,
            %{
              "revision" => 2,
              "url" => "https://gemini.google.com/app",
              "title" => "Observed",
              "semantic_tree" => [%{"node_id" => "submit"}]
            }} = Session.observe(context.supervisor, "session-1")
  end

  test "open fails and releases authority when the persistent profile starts off-origin",
       context do
    enqueue(context.adapter_state, [observation("Private", "https://evil.example/account")])

    assert {:error, :session_open_failed} = Session.open(context.supervisor, open_params())
    assert :error = ProfileLeaseServer.get(context.leases, "profile-1")

    assert {:ok, %{status: :failed, observation: nil}} =
             Journal.get(context.journal, :browser_session, "session-1")
  end

  test "an unconfirmed failed-open cleanup stays orphaned and retains its lease", context do
    enqueue(context.adapter_state, [observation("Private", "https://evil.example/account")])
    Agent.update(context.adapter_state, &Map.put(&1, :close_results, [{:error, :timeout}]))

    assert {:error, :session_open_failed} = Session.open(context.supervisor, open_params())

    assert {:ok, _authoritative_lease} =
             ProfileLeaseServer.get(context.leases, "profile-1")

    assert {:ok, %{status: :orphaned, observation: nil}} =
             Journal.get(context.journal, :browser_session, "session-1")
  end

  test "an observe failure or lost lease makes ready false until a fresh reconcile", context do
    enqueue(context.adapter_state, [observation("Opened")])
    assert {:ok, %{"status" => "ready"}} = Session.open(context.supervisor, open_params())

    enqueue(context.adapter_state, [observation("Wrong", "https://evil.example/")])
    assert {:error, :navigation_not_allowed} = Session.observe(context.supervisor, "session-1")

    assert {:ok, %{status: :orphaned}} =
             Journal.get(context.journal, :browser_session, "session-1")

    assert {:error, :session_not_ready} =
             Session.act(context.supervisor, "session-1", action("blocked", 1))

    enqueue(context.adapter_state, [observation("Recovered")])

    assert {:ok, %{"status" => "ready", "revision" => 2}} =
             Session.reconcile(context.supervisor, "session-1")

    {:ok, lease} = ProfileLeaseServer.get(context.leases, "profile-1")
    :ok = ProfileLeaseServer.release(context.leases, "profile-1", lease.lease_id)

    assert {:ok, %{"status" => "orphaned"}} =
             Session.reconcile(context.supervisor, "session-1")
  end

  test "reconcile proves the remote profile is still running before restoring ready", context do
    assert {:ok, %{"status" => "ready"}} = Session.open(context.supervisor, open_params())

    Agent.update(context.adapter_state, fn state ->
      Map.put(state, :profile_status_result, {:error, :manager_unavailable})
    end)

    assert {:ok, %{"status" => "orphaned"}} =
             Session.reconcile(context.supervisor, "session-1")

    assert {:ok, %{status: :orphaned}} =
             Journal.get(context.journal, :browser_session, "session-1")

    assert {:error, :session_not_ready} =
             Session.act(context.supervisor, "session-1", action("blocked", 1))
  end

  test "rejects unconfigured origins before taking the authoritative lease", context do
    params = %{open_params() | "authorized_origins" => ["https://accounts.google.com"]}
    assert {:error, :invalid_origin_policy} = Session.open(context.supervisor, params)
    assert :error = ProfileLeaseServer.get(context.leases, "profile-1")
  end

  test "reconciles runner crashes from the durable session and remote lease authority", context do
    assert {:ok, %{"status" => "ready"}} = Session.open(context.supervisor, open_params())
    enqueue(context.adapter_state, [observation("Recovered")])
    runner = SessionSupervisor.runner(context.supervisor, "session-1")
    Process.exit(runner, :kill)

    assert eventually(fn ->
             case Session.reconcile(context.supervisor, "session-1") do
               {:ok, %{"status" => "ready"}} -> true
               _other -> false
             end
           end)

    {:ok, lease} = ProfileLeaseServer.get(context.leases, "profile-1")
    :ok = ProfileLeaseServer.release(context.leases, "profile-1", lease.lease_id)
    runner = SessionSupervisor.runner(context.supervisor, "session-1")
    Process.exit(runner, :kill)

    assert eventually(fn ->
             case Session.reconcile(context.supervisor, "session-1") do
               {:ok, %{"status" => "orphaned"}} -> true
               _other -> false
             end
           end)
  end

  test "enforces the advertised session concurrency cap", context do
    assert {:ok, %{"status" => "ready"}} = Session.open(context.supervisor, open_params())

    params =
      open_params()
      |> Map.put("central_session_id", "central-2")
      |> Map.put("profile_id", "profile-2")

    assert {:error, :session_capacity_exceeded} = Session.open(context.supervisor, params)
  end

  test "same-profile admission reports profile_busy before the generic capacity limit", context do
    enqueue(context.adapter_state, [observation("Opened")])
    assert {:ok, %{"status" => "ready"}} = Session.open(context.supervisor, open_params())

    params = Map.put(open_params(), "central_session_id", "central-2")
    assert {:error, :profile_busy} = Session.open(context.supervisor, params)
  end

  test "open is idempotent by central session id and rejects collisions", context do
    assert {:ok, first} = Session.open(context.supervisor, open_params())
    assert {:ok, second} = Session.open(context.supervisor, open_params())
    assert second == first

    collision = Map.put(open_params(), "profile_id", "profile-2")

    assert {:error, :central_session_id_collision} =
             Session.open(context.supervisor, collision)

    assert :error = ProfileLeaseServer.get(context.leases, "profile-2")
  end

  test "failed browser setup is durable and releases its lease", context do
    Agent.update(context.adapter_state, &Map.put(&1, :factory_result, :error))

    assert {:error, :session_open_failed} = Session.open(context.supervisor, open_params())
    assert :error = ProfileLeaseServer.get(context.leases, "profile-1")

    assert {:ok, %{status: :failed}} =
             Journal.get(context.journal, :browser_session, "session-1")
  end

  test "ambiguous close retains authority until reconcile confirms closure", context do
    assert {:ok, %{"status" => "ready"}} = Session.open(context.supervisor, open_params())
    Agent.update(context.adapter_state, &Map.put(&1, :close_results, [{:error, :timeout}, :ok]))

    assert {:error, :session_close_unconfirmed} = Session.close(context.supervisor, "session-1")
    assert {:ok, _lease} = ProfileLeaseServer.get(context.leases, "profile-1")

    assert {:ok, %{status: :orphaned, close_uncertain: true}} =
             Journal.get(context.journal, :browser_session, "session-1")

    assert {:ok, %{"status" => "closed"}} = Session.reconcile(context.supervisor, "session-1")
    assert :error = ProfileLeaseServer.get(context.leases, "profile-1")
  end

  test "a recovered Commander close RPC replays a terminal session without reviving it",
       context do
    assert {:ok, %{"status" => "ready"}} = Session.open(context.supervisor, open_params())
    assert {:ok, %{"status" => "closed"}} = Session.close(context.supervisor, "session-1")
    assert eventually(fn -> is_nil(SessionSupervisor.runner(context.supervisor, "session-1")) end)

    request = rpc("session.close", %{"session_id" => "session-1"})
    assert {:ok, old_generation} = RequestDedup.begin_generation(context.journal)
    assert :execute = RequestDedup.claim(context.journal, request, old_generation)

    {:ok, registry} = CapabilityRegistry.start_link(name: nil)

    {:ok, capability} =
      Capability.start_link(
        name: nil,
        registry: registry,
        monitor: self(),
        journal: context.journal,
        lease_server: context.leases,
        backend: Backend,
        settings: context.settings,
        session_supervisor: context.supervisor,
        session_api: Session
      )

    on_exit(fn ->
      safe_stop(capability, &GenServer.stop/1)
      safe_stop(registry, &GenServer.stop/1)
    end)

    assert {:ok, %{"status" => "closed"} = recovered} =
             GenServer.call(capability, {:rpc, request})

    assert {:ok, ^recovered} = GenServer.call(capability, {:rpc, request})
    assert nil == SessionSupervisor.runner(context.supervisor, "session-1")

    assert {:ok, %{status: :closed}} =
             Journal.get(context.journal, :browser_session, "session-1")
  end

  test "a duplicate completed action response never rolls the durable revision backward",
       context do
    assert {:ok, %{"status" => "ready"}} = Session.open(context.supervisor, open_params())
    enqueue(context.adapter_state, [observation("Initial"), observation("After click")])
    assert {:ok, %{"revision" => 2}} = Session.observe(context.supervisor, "session-1")

    assert {:ok, %{"revision" => 3}} =
             Session.act(context.supervisor, "session-1", action("a", 2))

    enqueue(context.adapter_state, [observation("Newest")])
    assert {:ok, %{"revision" => 4}} = Session.observe(context.supervisor, "session-1")

    assert {:ok, %{"revision" => 3}} =
             Session.act(context.supervisor, "session-1", action("a", 2))

    assert {:ok, %{revision: 4, observation: %{"title" => "Newest"}}} =
             Journal.get(context.journal, :browser_session, "session-1")
  end

  test "an unknown action outcome remains blocked through reconcile without redispatch",
       context do
    assert {:ok, %{"status" => "ready"}} = Session.open(context.supervisor, open_params())
    enqueue(context.adapter_state, [observation("Initial")])
    assert {:ok, %{"revision" => 2}} = Session.observe(context.supervisor, "session-1")
    Agent.update(context.adapter_state, &Map.put(&1, :action_result, {:error, :cdp_timeout}))

    assert {:error, :action_outcome_unknown} =
             Session.act(context.supervisor, "session-1", action("unknown", 2))

    assert {:ok, %{status: :orphaned}} =
             Journal.get(context.journal, :browser_session, "session-1")

    assert {:ok, %{"status" => "orphaned"}} = Session.reconcile(context.supervisor, "session-1")

    assert {:error, :session_not_ready} =
             Session.act(context.supervisor, "session-1", action("another", 2))

    assert [{:click, _target}] = Agent.get(context.adapter_state, & &1.executions)
  end

  test "a generic CDP action failure cannot leave the session falsely ready", context do
    assert {:ok, %{"status" => "ready"}} = Session.open(context.supervisor, open_params())

    Agent.update(
      context.adapter_state,
      &Map.put(&1, :action_result, {:error, :cdp_pending_limit})
    )

    assert {:error, :action_failed} =
             Session.act(context.supervisor, "session-1", action("failed", 1))

    assert {:ok, %{status: :orphaned}} =
             Journal.get(context.journal, :browser_session, "session-1")

    assert {:error, :session_not_ready} =
             Session.act(context.supervisor, "session-1", action("blocked", 1))
  end

  test "runner restart marks a persisted executing action unknown without dispatch", context do
    assert {:ok, %{"status" => "ready"}} = Session.open(context.supervisor, open_params())

    :ok =
      Journal.put(context.journal, :pending_action, {"session-1", "crashed"}, %{
        status: :executing,
        history: [:received, :journaled, :validating, :executing]
      })

    runner = SessionSupervisor.runner(context.supervisor, "session-1")
    Process.exit(runner, :kill)

    assert eventually(fn ->
             match?(
               {:ok, %{"status" => "orphaned"}},
               Session.reconcile(context.supervisor, "session-1")
             )
           end)

    assert {:ok, %{status: :outcome_unknown, retryable: false}} =
             Journal.get(context.journal, :pending_action, {"session-1", "crashed"})

    assert [] = Agent.get(context.adapter_state, & &1.executions)
  end

  test "runner recovery reconciles a journaled closing session instead of reopening it",
       context do
    enqueue(context.adapter_state, [observation("Opened")])
    assert {:ok, %{"status" => "ready"}} = Session.open(context.supervisor, open_params())

    assert {:ok, session} = Journal.get(context.journal, :browser_session, "session-1")

    :ok =
      Journal.put(context.journal, :browser_session, "session-1", %{session | status: :closing})

    runner = SessionSupervisor.runner(context.supervisor, "session-1")
    Process.exit(runner, :kill)

    assert eventually(fn ->
             match?(
               {:ok, %{status: :closed}},
               Journal.get(context.journal, :browser_session, "session-1")
             )
           end)

    assert :error = ProfileLeaseServer.get(context.leases, "profile-1")
    assert [] = Agent.get(context.adapter_state, & &1.executions)
  end

  test "manual resume stays blocked when its mandatory fresh observation fails", context do
    assert {:ok, %{"status" => "ready"}} = Session.open(context.supervisor, open_params())
    enqueue(context.adapter_state, [observation("Initial")])
    assert {:ok, %{"revision" => 2}} = Session.observe(context.supervisor, "session-1")

    assert {:ok, %{"status" => "waiting_human"}} =
             Session.manual_handoff(context.supervisor, "session-1", "operator")

    Agent.update(context.adapter_state, &Map.put(&1, :fallback_observation, nil))

    assert {:error, :observation_failed} =
             Session.resume_automation(context.supervisor, "session-1")

    assert {:ok, %{status: :orphaned, revision: 2}} =
             Journal.get(context.journal, :browser_session, "session-1")

    assert {:error, :session_not_ready} =
             Session.act(context.supervisor, "session-1", action("blocked", 1))
  end

  test "runner death closes its old production CDP owner before one fresh connection", context do
    suffix = System.unique_integer([:positive])
    registry = String.to_atom("production_session_registry_#{suffix}")
    runners = String.to_atom("production_session_runners_#{suffix}")
    cdp = String.to_atom("production_session_cdp_#{suffix}")

    {:ok, supervisor} =
      SessionSupervisor.start_link(
        name: nil,
        registry_name: registry,
        runner_supervisor_name: runners,
        cdp_supervisor_name: cdp,
        journal: context.journal,
        lease_server: context.leases,
        settings: context.settings,
        backend: Backend,
        backend_opts: [test_pid: self()],
        cdp_client_opts: [transport: Transport, transport_opts: [test_pid: self()]],
        id_generator: fn -> "production-session" end
      )

    on_exit(fn -> safe_stop(supervisor, &Supervisor.stop/1) end)

    assert {:ok, %{"status" => "ready"}} = Session.open(supervisor, open_params())
    assert_receive {:transport_open, first_socket}
    first_runner = SessionSupervisor.runner(supervisor, "production-session")
    Process.exit(first_runner, :kill)

    assert_receive {:transport_closed, first_ref}
    assert first_ref == first_socket.ref
    assert_receive {:transport_open, second_socket}
    refute second_socket.ref == first_socket.ref

    assert eventually(fn ->
             case Session.reconcile(supervisor, "production-session") do
               {:ok, %{"status" => "ready", "revision" => revision}} when revision >= 2 -> true
               _other -> false
             end
           end)

    assert %{active: 1} = DynamicSupervisor.count_children(cdp)

    second_runner = SessionSupervisor.runner(supervisor, "production-session")
    second_client = :sys.get_state(second_runner).browser_resource.client
    Process.exit(second_client, :kill)

    assert eventually(fn ->
             match?(
               {:ok, %{status: :orphaned}},
               Journal.get(context.journal, :browser_session, "production-session")
             )
           end)

    assert {:ok, %{"status" => "ready"}} = Session.reconcile(supervisor, "production-session")
    assert_receive {:transport_open, third_socket}
    refute third_socket.ref in [first_socket.ref, second_socket.ref]
    assert %{active: 1} = DynamicSupervisor.count_children(cdp)

    old_cdp_supervisor = Process.whereis(cdp)
    Process.exit(old_cdp_supervisor, :kill)

    assert eventually(fn ->
             case Process.whereis(cdp) do
               pid when is_pid(pid) -> pid != old_cdp_supervisor
               nil -> false
             end
           end)

    assert eventually(fn ->
             match?(
               {:ok, %{status: :orphaned}},
               Journal.get(context.journal, :browser_session, "production-session")
             )
           end)

    assert {:ok, %{"status" => "ready"}} = Session.reconcile(supervisor, "production-session")
    assert_receive {:transport_open, fourth_socket}
    refute fourth_socket.ref in [first_socket.ref, second_socket.ref, third_socket.ref]
    assert %{active: 1} = DynamicSupervisor.count_children(cdp)
  end

  test "session expiry reconciles closure and retains an unconfirmed lease", context do
    params = Map.put(open_params(), "ttl_ms", 1_000)
    Agent.update(context.adapter_state, &Map.put(&1, :close_results, [{:error, :timeout}, :ok]))
    assert {:ok, %{"status" => "ready"}} = Session.open(context.supervisor, params)

    assert eventually(
             fn ->
               match?(
                 {:ok, %{status: :orphaned, close_uncertain: true}},
                 Journal.get(context.journal, :browser_session, "session-1")
               )
             end,
             200
           )

    assert {:ok, _expired_but_authoritative} =
             ProfileLeaseServer.get(context.leases, "profile-1")

    assert {:ok, %{"status" => "closed"}} =
             Session.reconcile(context.supervisor, "session-1")

    assert :error = ProfileLeaseServer.get(context.leases, "profile-1")
  end

  defp open_params do
    %{
      "central_session_id" => "central-1",
      "profile_id" => "profile-1",
      "mode" => "automation",
      "authorized_origins" => ["https://gemini.google.com"],
      "ttl_ms" => 60_000
    }
  end

  defp action(id, revision) do
    %{
      "action_id" => id,
      "session_id" => "session-1",
      "expected_revision" => revision,
      "type" => "click",
      "locator" => %{"node_id" => "submit"},
      "timeout_ms" => 5_000
    }
  end

  defp rpc(operation, payload) do
    %RPCRequest{
      protocol_version: 1,
      request_id: "11111111-1111-4111-8111-111111111111",
      capability: "browser.control",
      capability_version: 1,
      operation: operation,
      idempotency_key: "session-close-recovery",
      deadline_at: DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_iso8601(),
      payload: payload
    }
  end

  defp observation(title, url \\ "https://gemini.google.com/app") do
    %{
      "url" => url,
      "title" => title,
      "nodes" => [
        %{
          "node_id" => "submit",
          "backend_node_id" => 41,
          "role" => "button",
          "name" => "Submit",
          "depth" => 1,
          "visible" => true
        }
      ]
    }
  end

  defp enqueue(agent, observations),
    do: Agent.update(agent, &Map.put(&1, :observations, observations))

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp safe_stop(pid, fun) do
    if Process.alive?(pid), do: fun.(pid)
  catch
    :exit, _reason -> :ok
  end
end
