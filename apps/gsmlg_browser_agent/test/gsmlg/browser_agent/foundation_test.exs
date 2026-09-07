defmodule GSMLG.BrowserAgent.FoundationTest do
  use ExUnit.Case, async: false

  alias GSMLG.BrowserAgent.{Capability, Journal, ManagerMonitor, ProfileLeaseServer, Settings}
  alias GSMLG.Commander.CapabilityRegistry
  alias GSMLG.Commander.Protocol.Capability, as: CapabilityDescriptor
  alias GSMLG.Commander.Protocol.RPCRequest

  defmodule Backend do
    @behaviour GSMLG.BrowserAgent.Backend

    @impl true
    def manager_status(_settings, opts) do
      send(opts[:test_pid], :manager_polled)

      {:ok,
       %{
         "status" => "available",
         "binary_version" => "0.3.31",
         "profiles_total" => 1,
         "running_count" => 0,
         "host_os" => "linux",
         "runtime_mode" => "docker",
         "viewer_mode" => "vnc",
         "license_tier" => "keyless"
       }}
    end

    @impl true
    def list_profiles(_settings, _opts), do: {:ok, []}
    @impl true
    def get_profile(_settings, profile_id, _opts), do: {:ok, %{"id" => profile_id}}
    @impl true
    def profile_status(_settings, _profile_id, _opts), do: {:ok, %{"status" => "stopped"}}
    @impl true
    def launch_profile(_settings, profile_id, _opts),
      do: {:ok, %{"profile_id" => profile_id, "status" => "running"}}

    @impl true
    def stop_profile(_settings, _profile_id, _opts), do: {:ok, %{"status" => "stopped"}}
  end

  defmodule FailingBackend do
    @behaviour GSMLG.BrowserAgent.Backend

    @impl true
    def manager_status(_settings, _opts) do
      {:error,
       %{
         class: "manager",
         code: "manager_unavailable",
         message: "manager-secret appeared in a connection error",
         retryable: true,
         details: %{"body" => "private response body"}
       }}
    end

    @impl true
    def list_profiles(_settings, _opts), do: {:ok, []}
    @impl true
    def get_profile(_settings, profile_id, _opts), do: {:ok, %{"id" => profile_id}}
    @impl true
    def profile_status(_settings, _profile_id, _opts), do: {:ok, %{"status" => "stopped"}}
    @impl true
    def launch_profile(_settings, profile_id, _opts),
      do: {:ok, %{"profile_id" => profile_id, "status" => "running"}}

    @impl true
    def stop_profile(_settings, _profile_id, _opts), do: {:ok, %{"status" => "stopped"}}
  end

  defmodule SessionAPI do
    def open(test_pid, payload) do
      send(test_pid, {:session_open, payload})
      {:ok, %{"remote_session_id" => "remote-1", "status" => "ready"}}
    end

    def observe(test_pid, session_id) do
      send(test_pid, {:session_observe, session_id})

      {:ok,
       %{
         "session_id" => session_id,
         "lease_id" => "lease-1",
         "revision" => 1,
         "url" => "https://gemini.google.com/app",
         "origin" => "https://gemini.google.com",
         "title" => "Gemini",
         "semantic_tree" => [%{"node_id" => "submit", "role" => "button"}],
         "visible_controls" => [%{"node_id" => "submit", "role" => "button"}],
         "alerts" => []
       }}
    end

    def act(_test_pid, _session_id, %{"force_unknown" => true}),
      do: {:error, :action_outcome_unknown}

    def act(test_pid, session_id, action) do
      send(test_pid, {:session_act, session_id, action})
      {:ok, %{"remote_session_id" => session_id, "revision" => 2}}
    end

    def close(test_pid, session_id) do
      send(test_pid, {:session_close, session_id})
      {:ok, %{"remote_session_id" => session_id, "status" => "closed"}}
    end
  end

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    settings =
      Settings.load!(
        %{
          enabled: true,
          backend: "cloakbrowser",
          manager_url: "http://127.0.0.1:8080",
          manager_token_env: "IGNORED",
          state_dir: tmp_dir,
          max_concurrent_sessions: 1,
          max_concurrent_workflows: 1,
          security: %{allowed_upload_origins: ["https://uploads.example.test"]}
        },
        manager_token: "secret"
      )

    {:ok, journal} =
      Journal.start_link(
        name: nil,
        path: Path.join(tmp_dir, "foundation.dets"),
        dets_name: :browser_agent_foundation_journal_test
      )

    {:ok, leases} = ProfileLeaseServer.start_link(name: nil, journal: journal)

    on_exit(fn ->
      if Process.alive?(leases), do: GenServer.stop(leases)
      if Process.alive?(journal), do: GenServer.stop(journal)
      _ = :dets.close(:browser_agent_foundation_journal_test)
    end)

    %{settings: settings, journal: journal, leases: leases}
  end

  test "settings fail closed when enabled without a loopback Manager URL or runtime token" do
    base = %{
      enabled: true,
      backend: "cloakbrowser",
      manager_token_env: "MISSING_TOKEN",
      state_dir: "/var/lib/gsmlg/browser-agent"
    }

    assert {:error, :manager_token_missing} =
             Settings.load(Map.put(base, :manager_url, "http://127.0.0.1:8080"),
               env: fn _ -> nil end
             )

    assert {:error, :manager_url_not_loopback} =
             Settings.load(Map.put(base, :manager_url, "http://manager.example.test:8080"),
               manager_token: "secret"
             )

    assert {:error, :manager_url_invalid} =
             Settings.load(%{enabled: false, manager_url: nil})
  end

  test "settings carry the controlled CSS locator policy switch" do
    assert {:ok, settings} =
             Settings.load(
               %{
                 enabled: true,
                 manager_url: "http://127.0.0.1:8080",
                 manager_token_env: "IGNORED",
                 state_dir: "/tmp/browser-agent",
                 security: %{
                   allowed_origins: ["https://gemini.google.com"],
                   allowed_upload_origins: ["https://uploads.example.test"],
                   allow_css_locator: true
                 }
               },
               manager_token: "secret"
             )

    assert settings.allow_css_locator == true
  end

  test "enabled settings require unique canonical HTTPS workflow origins" do
    base = %{
      enabled: true,
      manager_url: "http://127.0.0.1:8080",
      manager_token_env: "IGNORED",
      state_dir: "/tmp/browser-agent"
    }

    assert {:error, :invalid_allowed_origins} =
             Settings.load(
               Map.put(base, :security, %{
                 allowed_origins: ["https://gemini.google.com", "https://gemini.google.com"],
                 allowed_upload_origins: ["https://uploads.example.test"]
               }),
               manager_token: "secret"
             )

    assert {:error, :invalid_allowed_origins} =
             Settings.load(
               Map.put(base, :security, %{
                 allowed_origins: ["http://gemini.google.com"],
                 allowed_upload_origins: ["https://uploads.example.test"]
               }),
               manager_token: "secret"
             )

    assert {:error, :invalid_allowed_upload_origins} =
             Settings.load(
               Map.put(base, :security, %{
                 allowed_origins: ["https://gemini.google.com"],
                 allowed_upload_origins: ["https://uploads.example.test/path"]
               }),
               manager_token: "secret"
             )
  end

  test "settings expose bounded journal retention and recovery defaults" do
    assert {:ok, settings} = Settings.load(%{enabled: false})

    assert settings.journal_terminal_max_records == 10_000
    assert settings.journal_terminal_max_age_ms == 2_592_000_000
    assert settings.journal_terminal_max_bytes == 67_108_864
    assert settings.journal_recovery_scan_max_records == 10_000
    assert settings.max_observation_bytes == 1_048_576
    assert settings.max_artifact_bytes == 104_857_600
    assert settings.inline_artifact_max_bytes == 131_072
    assert settings.allowed_upload_origins == []

    assert {:error, :invalid_positive_setting} =
             Settings.load(%{
               enabled: false,
               journal_terminal_max_records: 0
             })

    assert {:error, :journal_result_budget_too_small} =
             Settings.load(%{
               enabled: false,
               max_response_bytes: 1_024,
               journal_terminal_max_bytes: 2_047
             })

    assert {:error, :invalid_size_limit} =
             Settings.load(%{
               enabled: false,
               inline_artifact_max_bytes: 131_073
             })
  end

  test "Manager monitor keeps a sanitized health snapshot", %{settings: settings} do
    {:ok, monitor} =
      ManagerMonitor.start_link(
        name: nil,
        backend: Backend,
        settings: settings,
        backend_opts: [test_pid: self()],
        interval_ms: 60_000
      )

    assert_receive :manager_polled

    assert %{"status" => "available", "binary_version" => "0.3.31"} =
             ManagerMonitor.snapshot(monitor)

    GenServer.stop(monitor)
  end

  test "Manager monitor exposes only a stable error code when the backend fails", %{
    settings: settings
  } do
    {:ok, monitor} =
      ManagerMonitor.start_link(
        name: nil,
        backend: FailingBackend,
        settings: settings,
        interval_ms: 60_000
      )

    snapshot = ManagerMonitor.snapshot(monitor)

    assert snapshot == %{
             "status" => "degraded",
             "backend" => "cloakbrowser",
             "agent_version" => "0.1.0",
             "error_code" => "manager_unavailable"
           }

    encoded = JSON.encode!(snapshot)
    refute encoded =~ "manager-secret"
    refute encoded =~ "private response body"
    GenServer.stop(monitor)
  end

  test "registers the browser.control/v1 foundation descriptor with Commander", context do
    settings = context.settings
    {:ok, registry} = CapabilityRegistry.start_link(name: nil)

    {:ok, monitor} =
      ManagerMonitor.start_link(
        name: nil,
        backend: Backend,
        settings: settings,
        backend_opts: [test_pid: self()],
        interval_ms: 60_000
      )

    {:ok, capability} =
      Capability.start_link(
        name: nil,
        registry: registry,
        monitor: monitor,
        journal: context.journal,
        lease_server: context.leases,
        backend: Backend,
        settings: settings,
        backend_opts: [test_pid: self()],
        session_supervisor: self(),
        session_api: SessionAPI
      )

    assert {:ok,
            {%CapabilityDescriptor{
               id: "browser.control",
               version: 1,
               backend: "cloakbrowser",
               operations: operations,
               limits: %{
                 "max_profiles_running" => 1,
                 "max_sessions" => 1,
                 "max_workflows" => 1
               },
               workflows: ["gemini.deep_research/v1", "gemini.youtube_analysis/v1"]
             }, ^capability}} = CapabilityRegistry.fetch(registry, "browser.control")

    assert operations == [
             "manager.status",
             "profiles.list",
             "profile.status",
             "profile.launch",
             "profile.stop",
             "session.open",
             "session.observe",
             "session.act",
             "session.manual_acquire",
             "session.manual_release",
             "session.close",
             "workflow.start",
             "workflow.status",
             "workflow.cancel",
             "workflow.resume",
             "workflow.reconcile",
             "artifact.fetch_inline",
             "artifact.upload",
             "artifact.ack"
           ]

    assert {:ok, %{"status" => "available"}} =
             GenServer.call(capability, {:rpc, rpc("manager.status", %{})})

    assert {:ok, []} = GenServer.call(capability, {:rpc, rpc("profiles.list", %{})})

    assert {:ok, %{"status" => "stopped"}} =
             GenServer.call(
               capability,
               {:rpc, rpc("profile.status", %{"profile_id" => "profile-1"})}
             )

    assert {:error, %{code: "invalid_operation_payload", details: %{}}} =
             GenServer.call(
               capability,
               {:rpc, rpc("profile.status", %{"profile_id" => "profile-1", "extra" => true})}
             )

    open_payload = %{
      "central_session_id" => "central-1",
      "profile_id" => "profile-1",
      "mode" => "automation",
      "authorized_origins" => ["https://gemini.google.com"],
      "ttl_ms" => 60_000
    }

    assert {:ok, %{"remote_session_id" => "remote-1"}} =
             GenServer.call(capability, {:rpc, rpc("session.open", open_payload)})

    assert_receive {:session_open, ^open_payload}

    assert {:ok,
            %{
              "session_id" => "remote-1",
              "revision" => 1,
              "origin" => "https://gemini.google.com",
              "semantic_tree" => [%{"node_id" => "submit"}]
            }} =
             GenServer.call(
               capability,
               {:rpc, rpc("session.observe", %{"session_id" => "remote-1"})}
             )

    action = %{"action_id" => "a-1"}

    assert {:ok, %{"revision" => 2}} =
             GenServer.call(
               capability,
               {:rpc, rpc("session.act", %{"session_id" => "remote-1", "action" => action})}
             )

    assert_receive {:session_act, "remote-1", ^action}

    assert {:error,
            %{
              class: "action",
              code: "action_outcome_unknown",
              retryable: false,
              human_action: "reconcile",
              details: %{}
            }} =
             GenServer.call(
               capability,
               {:rpc,
                rpc("session.act", %{
                  "session_id" => "remote-1",
                  "action" => %{"force_unknown" => true}
                })}
             )

    assert {:ok, %{"status" => "closed"}} =
             GenServer.call(
               capability,
               {:rpc, rpc("session.close", %{"session_id" => "remote-1"})}
             )

    GenServer.stop(capability)
    GenServer.stop(monitor)
    GenServer.stop(registry)
  end

  test "does not dispatch a request whose deadline expires in the capability mailbox", context do
    {:ok, registry} = CapabilityRegistry.start_link(name: nil)

    {:ok, monitor} =
      ManagerMonitor.start_link(
        name: nil,
        backend: Backend,
        settings: context.settings,
        backend_opts: [test_pid: self()],
        interval_ms: 60_000
      )

    {:ok, capability} =
      Capability.start_link(
        name: nil,
        registry: registry,
        monitor: monitor,
        journal: context.journal,
        lease_server: context.leases,
        backend: Backend,
        settings: context.settings,
        backend_opts: [test_pid: self()],
        session_supervisor: self(),
        session_api: SessionAPI
      )

    request =
      rpc("session.act", %{
        "session_id" => "remote-1",
        "action" => %{"action_id" => "expired-in-queue"}
      })

    request = %{
      request
      | deadline_at: DateTime.utc_now() |> DateTime.add(50, :millisecond) |> DateTime.to_iso8601()
    }

    :sys.suspend(capability)
    task = Task.async(fn -> GenServer.call(capability, {:rpc, request}, 1_000) end)
    Process.sleep(75)
    :sys.resume(capability)

    assert {:error, %{code: "deadline_exceeded", retryable: false}} = Task.await(task)
    refute_receive {:session_act, "remote-1", _action}

    GenServer.stop(capability)
    GenServer.stop(monitor)
    GenServer.stop(registry)
  end

  test "release composition includes Browser Agent only in remote Commander release" do
    releases = GSMLG.Umbrella.MixProject.project()[:releases]
    assert get_in(releases, [:gsmlg_commander, :applications, :gsmlg_browser_agent]) == :permanent
    refute get_in(releases, [:gsmlg_umbrella, :applications, :gsmlg_browser_agent])
    refute get_in(releases, [:gsmlg_umbrella_standalone, :applications, :gsmlg_browser_agent])
  end

  defp rpc(operation, payload) do
    fingerprint =
      {operation, payload}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:md5, &1))
      |> Base.encode16(case: :lower)

    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12)>> = fingerprint

    %RPCRequest{
      protocol_version: 1,
      request_id: Enum.join([a, b, c, d, e], "-"),
      capability: "browser.control",
      capability_version: 1,
      operation: operation,
      idempotency_key: "foundation-#{fingerprint}",
      deadline_at: DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_iso8601(),
      payload: payload
    }
  end
end
