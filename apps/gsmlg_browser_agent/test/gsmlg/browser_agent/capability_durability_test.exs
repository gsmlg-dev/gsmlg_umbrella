defmodule GSMLG.BrowserAgent.CapabilityDurabilityTest do
  use ExUnit.Case, async: false

  alias GSMLG.BrowserAgent.{
    Capability,
    Journal,
    ManagerMonitor,
    ProfileLeaseServer,
    RequestDedup,
    Settings
  }

  alias GSMLG.Commander.CapabilityRegistry
  alias GSMLG.Commander.Protocol.RPCRequest

  @moduletag :tmp_dir

  defmodule Backend do
    @behaviour GSMLG.BrowserAgent.Backend

    @impl true
    def manager_status(_settings, _opts),
      do: {:ok, %{"status" => "available", "binary_version" => "test"}}

    @impl true
    def list_profiles(_settings, _opts), do: {:ok, []}
    @impl true
    def get_profile(_settings, profile_id, _opts), do: {:ok, %{"id" => profile_id}}
    @impl true
    def profile_status(_settings, _profile_id, _opts), do: {:ok, %{"status" => "stopped"}}

    @impl true
    def launch_profile(_settings, profile_id, opts) do
      send(opts[:test_pid], {:profile_launched, profile_id})
      {:ok, %{"profile_id" => profile_id, "status" => "running"}}
    end

    @impl true
    def stop_profile(_settings, profile_id, opts) do
      send(opts[:test_pid], {:profile_stopped, profile_id})
      {:ok, %{"profile_id" => profile_id, "status" => "stopped"}}
    end
  end

  defmodule StatefulBackend do
    @behaviour GSMLG.BrowserAgent.Backend

    @impl true
    def manager_status(_settings, _opts), do: {:ok, %{"status" => "available"}}
    @impl true
    def list_profiles(_settings, _opts), do: {:ok, []}
    @impl true
    def get_profile(_settings, profile_id, _opts), do: {:ok, %{"id" => profile_id}}

    @impl true
    def profile_status(_settings, profile_id, opts) do
      case Agent.get(opts[:profile_states], &Map.fetch!(&1, profile_id)) do
        status when status in ["running", "stopped"] ->
          {:ok, %{"status" => status}}

        :manager_uncertain ->
          {:error,
           %{
             class: "manager",
             code: "manager_timeout",
             message: "Manager timeout",
             retryable: true,
             details: %{}
           }}
      end
    end

    @impl true
    def launch_profile(_settings, profile_id, opts) do
      Agent.update(opts[:profile_states], &Map.put(&1, profile_id, "running"))
      send(opts[:test_pid], {:profile_launched, profile_id})
      {:ok, %{"profile_id" => profile_id, "status" => "running"}}
    end

    @impl true
    def stop_profile(_settings, profile_id, opts) do
      Agent.update(opts[:profile_states], &Map.put(&1, profile_id, "stopped"))
      send(opts[:test_pid], {:profile_stopped, profile_id})
      {:ok, %{"profile_id" => profile_id, "status" => "stopped"}}
    end
  end

  defmodule BlockingBackend do
    @behaviour GSMLG.BrowserAgent.Backend

    @impl true
    def manager_status(_settings, _opts), do: {:ok, %{"status" => "available"}}
    @impl true
    def list_profiles(_settings, _opts), do: {:ok, []}
    @impl true
    def get_profile(_settings, profile_id, _opts), do: {:ok, %{"id" => profile_id}}
    @impl true
    def profile_status(_settings, _profile_id, _opts), do: {:ok, %{"status" => "stopped"}}
    @impl true
    def launch_profile(_settings, profile_id, opts), do: block(:launch, profile_id, opts)
    @impl true
    def stop_profile(_settings, profile_id, opts), do: block(:stop, profile_id, opts)

    defp block(operation, profile_id, opts) do
      send(opts[:test_pid], {:mutation_started, operation, profile_id, self()})

      receive do: (:continue ->
                     {:ok, %{"profile_id" => profile_id, "status" => status(operation)}})
    end

    defp status(:launch), do: "running"
    defp status(:stop), do: "stopped"
  end

  defmodule AdmissionBackend do
    @behaviour GSMLG.BrowserAgent.Backend

    @impl true
    def manager_status(_settings, _opts), do: {:ok, %{"status" => "available"}}

    @impl true
    def list_profiles(_settings, opts) do
      profiles =
        Agent.get(opts[:profile_states], fn states ->
          Enum.map(states, fn {profile_id, status} ->
            %{"id" => profile_id, "status" => status}
          end)
        end)

      send(opts[:test_pid], {:profiles_listed, profiles})
      {:ok, profiles}
    end

    @impl true
    def get_profile(_settings, profile_id, _opts), do: {:ok, %{"id" => profile_id}}

    @impl true
    def profile_status(_settings, profile_id, opts) do
      {:ok, %{"status" => Agent.get(opts[:profile_states], &Map.fetch!(&1, profile_id))}}
    end

    @impl true
    def launch_profile(_settings, profile_id, opts) do
      if opts[:block_launch] == profile_id do
        send(opts[:test_pid], {:launch_mutation_started, profile_id, self()})
        receive do: (:continue -> :ok)
      end

      Agent.update(opts[:profile_states], &Map.put(&1, profile_id, "running"))
      send(opts[:test_pid], {:profile_launched, profile_id})
      {:ok, %{"profile_id" => profile_id, "status" => "running"}}
    end

    @impl true
    def stop_profile(_settings, profile_id, opts) do
      Agent.update(opts[:profile_states], &Map.put(&1, profile_id, "stopped"))
      send(opts[:test_pid], {:profile_stopped, profile_id})
      {:ok, %{"profile_id" => profile_id, "status" => "stopped"}}
    end
  end

  defmodule ErrorBackend do
    @behaviour GSMLG.BrowserAgent.Backend

    @impl true
    def manager_status(_settings, _opts), do: {:ok, %{"status" => "available"}}

    @impl true
    def list_profiles(_settings, opts) do
      send(opts[:test_pid], :profiles_listed_for_error_test)
      Agent.get(opts[:responses], & &1.list)
    end

    @impl true
    def get_profile(_settings, profile_id, _opts), do: {:ok, %{"id" => profile_id}}

    @impl true
    def profile_status(_settings, profile_id, opts) do
      send(opts[:test_pid], {:profile_status_checked, profile_id})
      Agent.get(opts[:responses], & &1.status)
    end

    @impl true
    def launch_profile(_settings, profile_id, opts) do
      send(opts[:test_pid], {:profile_launch_attempted, profile_id})
      Agent.get(opts[:responses], & &1.launch)
    end

    @impl true
    def stop_profile(_settings, profile_id, opts) do
      send(opts[:test_pid], {:profile_stop_attempted, profile_id})
      Agent.get(opts[:responses], & &1.stop)
    end
  end

  test "restart replays durable RPC outcome and rejects full-request operation collisions", %{
    tmp_dir: tmp_dir
  } do
    settings =
      Settings.load!(
        %{
          enabled: true,
          manager_url: "http://127.0.0.1:8080",
          manager_token_env: "IGNORED",
          state_dir: tmp_dir,
          security: %{allowed_upload_origins: ["https://uploads.example.test"]}
        },
        manager_token: "secret"
      )

    {:ok, journal} =
      Journal.start_link(
        name: nil,
        path: Path.join(tmp_dir, "capability.dets"),
        dets_name: :browser_agent_capability_journal_test
      )

    {:ok, leases} = ProfileLeaseServer.start_link(name: nil, journal: journal)
    {:ok, registry} = CapabilityRegistry.start_link(name: nil)

    {:ok, monitor} =
      ManagerMonitor.start_link(
        name: nil,
        backend: Backend,
        settings: settings,
        interval_ms: 60_000
      )

    request = rpc("profile.launch", %{"profile_id" => "profile-1"})

    {:ok, capability} =
      start_capability(settings, registry, monitor, leases, journal)

    assert {:ok, %{"status" => "running"}} =
             GenServer.call(capability, {:rpc, request})

    assert_receive {:profile_launched, "profile-1"}
    GenServer.stop(capability)
    GenServer.stop(leases)
    GenServer.stop(journal)

    {:ok, reopened_journal} =
      Journal.start_link(
        name: nil,
        path: Path.join(tmp_dir, "capability.dets"),
        dets_name: :browser_agent_capability_journal_test
      )

    {:ok, reopened_leases} = ProfileLeaseServer.start_link(name: nil, journal: reopened_journal)

    {:ok, restarted} =
      start_capability(settings, registry, monitor, reopened_leases, reopened_journal)

    assert {:ok, %{"status" => "running"}} = GenServer.call(restarted, {:rpc, request})
    refute_receive {:profile_launched, _}

    assert {:error, %{code: "request_payload_collision"}} =
             GenServer.call(
               restarted,
               {:rpc, %{request | operation: "profile.stop"}}
             )

    refute_receive {:profile_stopped, _}

    assert {:error, %{code: "idempotency_payload_collision"}} =
             GenServer.call(
               restarted,
               {:rpc,
                %{
                  request
                  | request_id: "22222222-2222-2222-2222-222222222222",
                    operation: "profile.stop"
                }}
             )

    refute_receive {:profile_stopped, _}

    GenServer.stop(restarted)
    GenServer.stop(monitor)
    GenServer.stop(registry)
    GenServer.stop(reopened_leases)
    GenServer.stop(reopened_journal)
    _ = :dets.close(:browser_agent_capability_journal_test)
  end

  test "prior-boot launch and stop claims reconcile before replay or safe mutation", %{
    tmp_dir: tmp_dir
  } do
    settings = settings(tmp_dir)

    {:ok, journal} =
      Journal.start_link(
        name: nil,
        path: Path.join(tmp_dir, "recovery.dets"),
        dets_name: :browser_agent_recovery_journal_test
      )

    {:ok, prior_generation} = RequestDedup.begin_generation(journal)

    requests = [
      rpc(
        "profile.launch",
        %{"profile_id" => "launch-done"},
        "10000000-0000-0000-0000-000000000001",
        "launch-done"
      ),
      rpc(
        "profile.stop",
        %{"profile_id" => "stop-done"},
        "10000000-0000-0000-0000-000000000002",
        "stop-done"
      ),
      rpc(
        "profile.launch",
        %{"profile_id" => "launch-needed"},
        "10000000-0000-0000-0000-000000000003",
        "launch-needed"
      ),
      rpc(
        "profile.stop",
        %{"profile_id" => "stop-needed"},
        "10000000-0000-0000-0000-000000000004",
        "stop-needed"
      )
    ]

    Enum.each(requests, fn request ->
      assert :execute = RequestDedup.claim(journal, request, prior_generation)
    end)

    GenServer.stop(journal)

    {:ok, journal} =
      Journal.start_link(
        name: nil,
        path: Path.join(tmp_dir, "recovery.dets"),
        dets_name: :browser_agent_recovery_journal_test
      )

    {:ok, states} =
      Agent.start_link(fn ->
        %{
          "launch-done" => "running",
          "stop-done" => "stopped",
          "launch-needed" => "stopped",
          "stop-needed" => "running"
        }
      end)

    {:ok, leases} = ProfileLeaseServer.start_link(name: nil, journal: journal)
    {:ok, registry} = CapabilityRegistry.start_link(name: nil)

    {:ok, monitor} =
      ManagerMonitor.start_link(
        name: nil,
        backend: StatefulBackend,
        settings: settings,
        interval_ms: 60_000
      )

    {:ok, capability} =
      Capability.start_link(
        name: nil,
        registry: registry,
        monitor: monitor,
        lease_server: leases,
        journal: journal,
        backend: StatefulBackend,
        settings: settings,
        backend_opts: [test_pid: self(), profile_states: states]
      )

    Enum.with_index(requests, 10)
    |> Enum.each(fn {request, index} ->
      retry = %{
        request
        | request_id:
            "20000000-0000-0000-0000-#{index |> Integer.to_string() |> String.pad_leading(12, "0")}"
      }

      expected = expected_status(request.operation)
      assert {:ok, %{"status" => ^expected}} = GenServer.call(capability, {:rpc, retry})
    end)

    refute_receive {:profile_launched, "launch-done"}
    refute_receive {:profile_stopped, "stop-done"}
    assert_receive {:profile_launched, "launch-needed"}
    assert_receive {:profile_stopped, "stop-needed"}

    Enum.each(requests, fn request ->
      expected = expected_status(request.operation)
      assert {:ok, %{"status" => ^expected}} = GenServer.call(capability, {:rpc, request})
    end)

    refute_receive {:profile_launched, _}
    refute_receive {:profile_stopped, _}

    GenServer.stop(capability)
    GenServer.stop(monitor)
    GenServer.stop(registry)
    GenServer.stop(leases)
    Agent.stop(states)
    GenServer.stop(journal)
    _ = :dets.close(:browser_agent_recovery_journal_test)
  end

  test "capability launch and stop serialize lease-free checks with Manager mutation", %{
    tmp_dir: tmp_dir
  } do
    settings = settings(tmp_dir)

    {:ok, journal} =
      Journal.start_link(
        name: nil,
        path: Path.join(tmp_dir, "serialization.dets"),
        dets_name: :browser_agent_capability_serialization_journal_test
      )

    {:ok, leases} = ProfileLeaseServer.start_link(name: nil, journal: journal)
    {:ok, registry} = CapabilityRegistry.start_link(name: nil)

    {:ok, monitor} =
      ManagerMonitor.start_link(
        name: nil,
        backend: BlockingBackend,
        settings: settings,
        interval_ms: 60_000
      )

    {:ok, capability} =
      Capability.start_link(
        name: nil,
        registry: registry,
        monitor: monitor,
        lease_server: leases,
        journal: journal,
        backend: BlockingBackend,
        settings: settings,
        backend_opts: [test_pid: self()]
      )

    for {operation, verb, profile_id, index} <- [
          {"profile.launch", :launch, "launch-profile", 1},
          {"profile.stop", :stop, "stop-profile", 2}
        ] do
      mutation =
        Task.async(fn ->
          GenServer.call(
            capability,
            {:rpc,
             rpc(
               operation,
               %{"profile_id" => profile_id},
               "30000000-0000-0000-0000-#{index |> Integer.to_string() |> String.pad_leading(12, "0")}",
               "serialized-#{verb}"
             )},
            :infinity
          )
        end)

      assert_receive {:mutation_started, ^verb, ^profile_id, mutation_owner}, 1_000

      acquisition =
        Task.async(fn ->
          ProfileLeaseServer.acquire(leases, profile_id, :automation, "job-#{index}",
            lease_id: "lease-#{index}",
            now: ~U[2026-09-04 00:00:00Z],
            ttl_ms: 60_000
          )
        end)

      assert Task.yield(acquisition, 50) == nil
      send(mutation_owner, :continue)
      expected = expected_status(operation)
      assert {:ok, %{"status" => ^expected}} = Task.await(mutation)
      assert {:ok, lease} = Task.await(acquisition)
      assert :ok = ProfileLeaseServer.release(leases, profile_id, lease.lease_id)
    end

    GenServer.stop(capability)
    GenServer.stop(monitor)
    GenServer.stop(registry)
    GenServer.stop(leases)
    GenServer.stop(journal)
    _ = :dets.close(:browser_agent_capability_serialization_journal_test)
  end

  test "uncertain recovery remains retryable in the same capability generation", %{
    tmp_dir: tmp_dir
  } do
    settings = settings(tmp_dir)

    {:ok, journal} =
      Journal.start_link(
        name: nil,
        path: Path.join(tmp_dir, "uncertain.dets"),
        dets_name: :browser_agent_uncertain_recovery_journal_test
      )

    request =
      rpc(
        "profile.launch",
        %{"profile_id" => "uncertain-profile"},
        "40000000-0000-0000-0000-000000000001",
        "uncertain-launch"
      )

    {:ok, prior_generation} = RequestDedup.begin_generation(journal)
    assert :execute = RequestDedup.claim(journal, request, prior_generation)
    {:ok, states} = Agent.start_link(fn -> %{"uncertain-profile" => :manager_uncertain} end)
    {:ok, leases} = ProfileLeaseServer.start_link(name: nil, journal: journal)
    {:ok, registry} = CapabilityRegistry.start_link(name: nil)

    {:ok, monitor} =
      ManagerMonitor.start_link(
        name: nil,
        backend: StatefulBackend,
        settings: settings,
        interval_ms: 60_000
      )

    {:ok, capability} =
      Capability.start_link(
        name: nil,
        registry: registry,
        monitor: monitor,
        lease_server: leases,
        journal: journal,
        backend: StatefulBackend,
        settings: settings,
        backend_opts: [test_pid: self(), profile_states: states]
      )

    assert {:error, %{code: "operation_outcome_unknown"}} =
             GenServer.call(capability, {:rpc, request})

    assert {:ok, %{status: :recoverable}} =
             Journal.get(journal, :request_dedup, request.request_id)

    Agent.update(states, &Map.put(&1, "uncertain-profile", "stopped"))

    assert {:ok, %{"status" => "running"}} =
             GenServer.call(capability, {:rpc, request})

    assert_receive {:profile_launched, "uncertain-profile"}

    assert {:ok, %{status: :completed}} =
             Journal.get(journal, :request_dedup, request.request_id)

    GenServer.stop(capability)
    GenServer.stop(monitor)
    GenServer.stop(registry)
    GenServer.stop(leases)
    Agent.stop(states)
    GenServer.stop(journal)
    _ = :dets.close(:browser_agent_uncertain_recovery_journal_test)
  end

  test "deterministic launch errors are durably completed and replay their sanitized code", %{
    tmp_dir: tmp_dir
  } do
    stack = start_error_stack(tmp_dir, :browser_agent_deterministic_errors_journal_test)

    errors = [
      {"profile_not_found", false},
      {"manager_invalid_request", false},
      {"manager_unauthorized", false},
      {"manager_license_denied", false}
    ]

    Enum.with_index(errors, 1)
    |> Enum.each(fn {{code, retryable}, index} ->
      Agent.update(stack.responses, fn responses ->
        %{responses | launch: manager_error(code, retryable)}
      end)

      request =
        rpc(
          "profile.launch",
          %{"profile_id" => "profile-error"},
          "91000000-0000-0000-0000-#{String.pad_leading(Integer.to_string(index), 12, "0")}",
          "deterministic-error-#{index}"
        )

      result = GenServer.call(stack.capability, {:rpc, request})
      assert {:error, %{code: ^code, retryable: ^retryable, details: %{}}} = result
      refute JSON.encode!(elem(result, 1)) =~ "secret backend"

      assert_receive {:profile_launch_attempted, "profile-error"}

      assert {:ok, %{status: :completed}} =
               Journal.get(stack.journal, :request_dedup, request.request_id)

      Agent.update(stack.responses, fn responses ->
        %{responses | launch: {:ok, %{"profile_id" => "profile-error", "status" => "running"}}}
      end)

      assert {:error, %{code: ^code, retryable: ^retryable}} =
               GenServer.call(stack.capability, {:rpc, request})

      refute_receive {:profile_launch_attempted, "profile-error"}
    end)

    stop_error_stack(stack, :browser_agent_deterministic_errors_journal_test)
  end

  test "pre-mutation admission errors complete unchanged because no launch was attempted", %{
    tmp_dir: tmp_dir
  } do
    stack = start_error_stack(tmp_dir, :browser_agent_admission_error_journal_test)

    errors = [
      {"manager_timeout", true},
      {"manager_invalid_response", false},
      {"manager_response_too_large", false},
      {"manager_license_denied", false}
    ]

    Enum.with_index(errors, 1)
    |> Enum.each(fn {{code, retryable}, index} ->
      Agent.update(stack.responses, fn responses ->
        %{responses | list: manager_error(code, retryable)}
      end)

      request =
        rpc(
          "profile.launch",
          %{"profile_id" => "profile-error"},
          "92000000-0000-0000-0000-#{String.pad_leading(Integer.to_string(index), 12, "0")}",
          "admission-error-#{index}"
        )

      assert {:error, %{class: "manager", code: ^code, retryable: ^retryable}} =
               GenServer.call(stack.capability, {:rpc, request})

      refute_receive {:profile_launch_attempted, _profile_id}

      assert {:ok, %{status: :completed}} =
               Journal.get(stack.journal, :request_dedup, request.request_id)
    end)

    stop_error_stack(stack, :browser_agent_admission_error_journal_test)
  end

  test "only ambiguous post-mutation launch and stop failures remain recoverable", %{
    tmp_dir: tmp_dir
  } do
    stack = start_error_stack(tmp_dir, :browser_agent_ambiguous_mutation_journal_test)

    launch =
      rpc(
        "profile.launch",
        %{"profile_id" => "profile-error"},
        "93000000-0000-0000-0000-000000000001",
        "ambiguous-launch"
      )

    assert {:error, %{code: "operation_outcome_unknown", retryable: true}} =
             GenServer.call(stack.capability, {:rpc, launch})

    assert_receive {:profile_launch_attempted, "profile-error"}

    assert {:ok, %{status: :recoverable}} =
             Journal.get(stack.journal, :request_dedup, launch.request_id)

    Agent.update(stack.responses, fn responses ->
      %{responses | stop: manager_error("manager_unavailable", true)}
    end)

    stop =
      rpc(
        "profile.stop",
        %{"profile_id" => "profile-error"},
        "93000000-0000-0000-0000-000000000002",
        "ambiguous-stop"
      )

    assert {:error, %{code: "operation_outcome_unknown", retryable: true}} =
             GenServer.call(stack.capability, {:rpc, stop})

    assert_receive {:profile_stop_attempted, "profile-error"}

    assert {:ok, %{status: :recoverable}} =
             Journal.get(stack.journal, :request_dedup, stop.request_id)

    stop_error_stack(stack, :browser_agent_ambiguous_mutation_journal_test)
  end

  test "malformed, oversized, and launch-conflict mutation responses remain recoverable", %{
    tmp_dir: tmp_dir
  } do
    stack = start_error_stack(tmp_dir, :browser_agent_mutation_response_journal_test)

    cases = [
      {"profile.launch", "manager_invalid_response", 1},
      {"profile.launch", "manager_response_too_large", 2},
      {"profile.launch", "profile_busy", 3},
      {"profile.stop", "manager_invalid_response", 4},
      {"profile.stop", "manager_response_too_large", 5}
    ]

    Enum.each(cases, fn {operation, code, index} ->
      key = if operation == "profile.launch", do: :launch, else: :stop

      Agent.update(stack.responses, fn responses ->
        Map.put(responses, key, manager_error(code, code == "profile_busy"))
      end)

      request =
        rpc(
          operation,
          %{"profile_id" => "profile-error"},
          "93500000-0000-0000-0000-#{String.pad_leading(Integer.to_string(index), 12, "0")}",
          "ambiguous-response-#{index}"
        )

      assert {:error, %{code: "operation_outcome_unknown", retryable: true}} =
               GenServer.call(stack.capability, {:rpc, request})

      assert {:ok, %{status: :recoverable}} =
               Journal.get(stack.journal, :request_dedup, request.request_id)
    end)

    stop_error_stack(stack, :browser_agent_mutation_response_journal_test)
  end

  test "recovery status 404 settles the durable request as profile_not_found", %{
    tmp_dir: tmp_dir
  } do
    request =
      rpc(
        "profile.stop",
        %{"profile_id" => "missing-profile"},
        "94000000-0000-0000-0000-000000000001",
        "missing-profile-stop"
      )

    stack =
      start_error_stack(tmp_dir, :browser_agent_missing_recovery_journal_test,
        prior_requests: [request]
      )

    Agent.update(stack.responses, fn responses ->
      %{responses | status: manager_error("profile_not_found", false)}
    end)

    assert {:error, %{code: "profile_not_found", retryable: false, details: %{}}} =
             GenServer.call(stack.capability, {:rpc, request})

    assert_receive {:profile_status_checked, "missing-profile"}
    refute_receive {:profile_stop_attempted, _profile_id}

    assert {:ok, %{status: :completed}} =
             Journal.get(stack.journal, :request_dedup, request.request_id)

    stop_error_stack(stack, :browser_agent_missing_recovery_journal_test)
  end

  test "recovery keeps every non-404 status verification failure recoverable", %{
    tmp_dir: tmp_dir
  } do
    codes = [
      "manager_timeout",
      "manager_unavailable",
      "manager_unauthorized",
      "manager_license_denied",
      "manager_invalid_response",
      "manager_response_too_large"
    ]

    requests =
      Enum.with_index(codes, 1)
      |> Enum.map(fn {_code, index} ->
        rpc(
          "profile.stop",
          %{"profile_id" => "profile-error"},
          "94500000-0000-0000-0000-#{String.pad_leading(Integer.to_string(index), 12, "0")}",
          "status-verification-#{index}"
        )
      end)

    stack =
      start_error_stack(tmp_dir, :browser_agent_status_verification_journal_test,
        prior_requests: requests
      )

    Enum.zip(codes, requests)
    |> Enum.each(fn {code, request} ->
      Agent.update(stack.responses, fn responses ->
        retryable = code in ["manager_timeout", "manager_unavailable"]
        %{responses | status: manager_error(code, retryable)}
      end)

      assert {:error, %{code: "operation_outcome_unknown", retryable: true}} =
               GenServer.call(stack.capability, {:rpc, request})

      assert {:ok, %{status: :recoverable}} =
               Journal.get(stack.journal, :request_dedup, request.request_id)
    end)

    refute_receive {:profile_stop_attempted, _profile_id}
    stop_error_stack(stack, :browser_agent_status_verification_journal_test)
  end

  test "sequential launches of different profiles enforce the advertised global limit", %{
    tmp_dir: tmp_dir
  } do
    stack =
      start_admission_stack(
        tmp_dir,
        :browser_agent_sequential_admission_journal_test,
        %{"profile-a" => "stopped", "profile-b" => "stopped"}
      )

    assert {:ok, %{"status" => "running"}} =
             GenServer.call(
               stack.capability,
               {:rpc,
                rpc(
                  "profile.launch",
                  %{"profile_id" => "profile-a"},
                  "50000000-0000-0000-0000-000000000001",
                  "launch-profile-a"
                )}
             )

    assert_receive {:profile_launched, "profile-a"}

    assert {:error, %{code: "profile_busy", details: %{}}} =
             GenServer.call(
               stack.capability,
               {:rpc,
                rpc(
                  "profile.launch",
                  %{"profile_id" => "profile-b"},
                  "50000000-0000-0000-0000-000000000002",
                  "launch-profile-b"
                )}
             )

    refute_receive {:profile_launched, "profile-b"}
    assert Agent.get(stack.states, & &1["profile-b"]) == "stopped"
    stop_admission_stack(stack, :browser_agent_sequential_admission_journal_test)
  end

  test "concurrent launches cannot both pass global admission", %{tmp_dir: tmp_dir} do
    stack =
      start_admission_stack(
        tmp_dir,
        :browser_agent_concurrent_admission_journal_test,
        %{"profile-a" => "stopped", "profile-b" => "stopped"},
        block_launch: "profile-a"
      )

    launch_a =
      Task.async(fn ->
        GenServer.call(
          stack.capability,
          {:rpc,
           rpc(
             "profile.launch",
             %{"profile_id" => "profile-a"},
             "60000000-0000-0000-0000-000000000001",
             "concurrent-launch-a"
           )},
          :infinity
        )
      end)

    assert_receive {:launch_mutation_started, "profile-a", mutation_owner}, 1_000

    launch_b =
      Task.async(fn ->
        GenServer.call(
          stack.capability,
          {:rpc,
           rpc(
             "profile.launch",
             %{"profile_id" => "profile-b"},
             "60000000-0000-0000-0000-000000000002",
             "concurrent-launch-b"
           )},
          :infinity
        )
      end)

    assert Task.yield(launch_b, 50) == nil
    send(mutation_owner, :continue)
    assert {:ok, %{"status" => "running"}} = Task.await(launch_a)
    assert {:error, %{code: "profile_busy"}} = Task.await(launch_b)
    assert_receive {:profile_launched, "profile-a"}
    refute_receive {:profile_launched, "profile-b"}
    stop_admission_stack(stack, :browser_agent_concurrent_admission_journal_test)
  end

  test "a lease on any profile blocks launching a different profile", %{tmp_dir: tmp_dir} do
    stack =
      start_admission_stack(
        tmp_dir,
        :browser_agent_lease_admission_journal_test,
        %{"profile-a" => "stopped", "profile-b" => "stopped"}
      )

    assert {:ok, _lease} =
             ProfileLeaseServer.acquire(stack.leases, "profile-a", :automation, "job-a",
               lease_id: "lease-a",
               now: ~U[2026-09-04 00:00:00Z],
               ttl_ms: 60_000
             )

    assert {:error, %{code: "profile_busy"}} =
             GenServer.call(
               stack.capability,
               {:rpc,
                rpc(
                  "profile.launch",
                  %{"profile_id" => "profile-b"},
                  "70000000-0000-0000-0000-000000000001",
                  "lease-blocked-launch"
                )}
             )

    refute_receive {:profiles_listed, _profiles}
    refute_receive {:profile_launched, "profile-b"}
    stop_admission_stack(stack, :browser_agent_lease_admission_journal_test)
  end

  test "recovered launch is rejected when another profile is already running", %{
    tmp_dir: tmp_dir
  } do
    request =
      rpc(
        "profile.launch",
        %{"profile_id" => "profile-b"},
        "80000000-0000-0000-0000-000000000001",
        "recovered-launch-b"
      )

    stack =
      start_admission_stack(
        tmp_dir,
        :browser_agent_recovery_admission_journal_test,
        %{"profile-a" => "running", "profile-b" => "stopped"},
        prior_requests: [request]
      )

    assert {:error, %{code: "profile_busy"}} =
             GenServer.call(stack.capability, {:rpc, request})

    assert_receive {:profiles_listed, profiles}
    assert %{"id" => "profile-a", "status" => "running"} in profiles
    refute_receive {:profile_launched, "profile-b"}
    stop_admission_stack(stack, :browser_agent_recovery_admission_journal_test)
  end

  defp start_capability(settings, registry, monitor, leases, journal) do
    Capability.start_link(
      name: nil,
      registry: registry,
      monitor: monitor,
      lease_server: leases,
      journal: journal,
      backend: Backend,
      settings: settings,
      backend_opts: [test_pid: self()]
    )
  end

  defp rpc(operation, payload) do
    rpc(
      operation,
      payload,
      "11111111-1111-1111-1111-111111111111",
      "durable-capability-request"
    )
  end

  defp rpc(operation, payload, request_id, idempotency_key) do
    %RPCRequest{
      protocol_version: 1,
      request_id: request_id,
      capability: "browser.control",
      capability_version: 1,
      operation: operation,
      idempotency_key: idempotency_key,
      deadline_at: DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_iso8601(),
      payload: payload
    }
  end

  defp settings(tmp_dir) do
    Settings.load!(
      %{
        enabled: true,
        manager_url: "http://127.0.0.1:8080",
        manager_token_env: "IGNORED",
        state_dir: tmp_dir,
        security: %{allowed_upload_origins: ["https://uploads.example.test"]}
      },
      manager_token: "secret"
    )
  end

  defp expected_status("profile.launch"), do: "running"
  defp expected_status("profile.stop"), do: "stopped"

  defp start_admission_stack(tmp_dir, dets_name, initial_states, opts \\ []) do
    settings = settings(tmp_dir)
    path = Path.join(tmp_dir, "#{dets_name}.dets")
    {:ok, journal} = Journal.start_link(name: nil, path: path, dets_name: dets_name)

    if prior_requests = opts[:prior_requests] do
      {:ok, prior_generation} = RequestDedup.begin_generation(journal)

      Enum.each(prior_requests, fn request ->
        :execute = RequestDedup.claim(journal, request, prior_generation)
      end)
    end

    {:ok, states} = Agent.start_link(fn -> initial_states end)
    {:ok, leases} = ProfileLeaseServer.start_link(name: nil, journal: journal)
    {:ok, registry} = CapabilityRegistry.start_link(name: nil)

    {:ok, monitor} =
      ManagerMonitor.start_link(
        name: nil,
        backend: AdmissionBackend,
        settings: settings,
        interval_ms: 60_000
      )

    backend_opts =
      [test_pid: self(), profile_states: states]
      |> Keyword.merge(Keyword.take(opts, [:block_launch]))

    {:ok, capability} =
      Capability.start_link(
        name: nil,
        registry: registry,
        monitor: monitor,
        lease_server: leases,
        journal: journal,
        backend: AdmissionBackend,
        settings: settings,
        backend_opts: backend_opts
      )

    %{
      capability: capability,
      journal: journal,
      leases: leases,
      monitor: monitor,
      registry: registry,
      states: states
    }
  end

  defp start_error_stack(tmp_dir, dets_name, opts \\ []) do
    settings = settings(tmp_dir)
    path = Path.join(tmp_dir, "#{dets_name}.dets")
    {:ok, journal} = Journal.start_link(name: nil, path: path, dets_name: dets_name)

    if prior_requests = opts[:prior_requests] do
      {:ok, prior_generation} = RequestDedup.begin_generation(journal)

      Enum.each(prior_requests, fn request ->
        :execute = RequestDedup.claim(journal, request, prior_generation)
      end)
    end

    {:ok, responses} =
      Agent.start_link(fn ->
        %{
          list: {:ok, [%{"id" => "profile-error", "status" => "stopped"}]},
          status: {:ok, %{"status" => "stopped"}},
          launch: manager_error("manager_timeout", true),
          stop: {:ok, %{"profile_id" => "profile-error", "status" => "stopped"}}
        }
      end)

    {:ok, leases} = ProfileLeaseServer.start_link(name: nil, journal: journal)
    {:ok, registry} = CapabilityRegistry.start_link(name: nil)

    {:ok, monitor} =
      ManagerMonitor.start_link(
        name: nil,
        backend: ErrorBackend,
        settings: settings,
        interval_ms: 60_000
      )

    {:ok, capability} =
      Capability.start_link(
        name: nil,
        registry: registry,
        monitor: monitor,
        lease_server: leases,
        journal: journal,
        backend: ErrorBackend,
        settings: settings,
        backend_opts: [test_pid: self(), responses: responses]
      )

    %{
      capability: capability,
      journal: journal,
      leases: leases,
      registry: registry,
      monitor: monitor,
      responses: responses
    }
  end

  defp stop_error_stack(stack, dets_name) do
    GenServer.stop(stack.capability)
    GenServer.stop(stack.monitor)
    GenServer.stop(stack.registry)
    GenServer.stop(stack.leases)
    Agent.stop(stack.responses)
    GenServer.stop(stack.journal)
    _ = :dets.close(dets_name)
  end

  defp manager_error(code, retryable) do
    {:error,
     %{
       class: "manager",
       code: code,
       message: "secret backend message",
       retryable: retryable,
       human_action: "none",
       details: %{"body" => "secret backend body"}
     }}
  end

  defp stop_admission_stack(stack, dets_name) do
    GenServer.stop(stack.capability)
    GenServer.stop(stack.monitor)
    GenServer.stop(stack.registry)
    GenServer.stop(stack.leases)
    Agent.stop(stack.states)
    GenServer.stop(stack.journal)
    _ = :dets.close(dets_name)
  end
end
