defmodule GSMLG.CommandPlatform.ControlPlaneTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias GSMLG.CommandPlatform.{
    AgentRegistry,
    CommandDispatcher,
    PendingRequestRegistry,
    ReplayCache,
    RPCDispatcher
  }

  alias GSMLG.CommandPlatform.{PTYSessionRecord, SessionTracker}
  alias GSMLG.Commander.Protocol.{EventAck, JobEvent, RPCAccepted, RPCRequest, RPCResponse}

  test "a late DOWN from a replaced same-name connection cannot remove the replacement" do
    agent_id = "reconnect-#{System.unique_integer([:positive])}"
    old_connection = spawn(fn -> receive do: (:stop -> :ok) end)
    new_connection = spawn(fn -> receive do: (:stop -> :ok) end)

    on_exit(fn ->
      if Process.alive?(old_connection), do: Process.exit(old_connection, :kill)
      if Process.alive?(new_connection), do: Process.exit(new_connection, :kill)
      AgentRegistry.unregister_agent(agent_id, new_connection)
    end)

    assert :ok = AgentRegistry.register_agent(agent_id, old_connection)
    assert :ok = AgentRegistry.register_agent(agent_id, new_connection)
    Process.exit(old_connection, :kill)
    Process.sleep(20)

    assert {:ok, %{channel_pid: ^new_connection, generation: generation}} =
             AgentRegistry.find_agent(agent_id)

    assert is_integer(generation)
  end

  test "dispatch routes a terminal response to its pending caller" do
    agent_id = "dispatch-#{System.unique_integer([:positive])}"
    request = request()
    caller = self()
    assert :ok = AgentRegistry.register_agent(agent_id, self())
    on_exit(fn -> AgentRegistry.unregister_agent(agent_id, self()) end)

    Task.start_link(fn ->
      send(caller, {:dispatch_result, RPCDispatcher.dispatch(agent_id, request, timeout: 500)})
    end)

    assert_receive {:commander_rpc, wire}
    assert wire["type"] == "rpc.request"

    response = %RPCResponse{
      protocol_version: 1,
      request_id: request.request_id,
      result: %{"status" => "healthy"}
    }

    assert {:error, :agent_mismatch} = RPCDispatcher.route_incoming("another-agent", response)
    refute_receive {:dispatch_result, _result}, 20

    assert :ok = RPCDispatcher.route_incoming(agent_id, response)
    assert_receive {:dispatch_result, {:ok, ^response}}
  end

  test "a concurrent duplicate dispatch cannot cancel the original pending request" do
    agent_id = "duplicate-dispatch-#{System.unique_integer([:positive])}"
    request = request()
    assert :ok = AgentRegistry.register_agent(agent_id, self())
    on_exit(fn -> AgentRegistry.unregister_agent(agent_id, self()) end)

    original = Task.async(fn -> RPCDispatcher.dispatch(agent_id, request, timeout: 500) end)
    assert_receive {:commander_rpc, _wire}, 500

    assert {:error, :request_in_progress} =
             RPCDispatcher.dispatch(agent_id, request, timeout: 500)

    refute_receive {:commander_rpc, _duplicate_wire}, 20

    response = %RPCResponse{
      protocol_version: 1,
      request_id: request.request_id,
      result: %{"status" => "original-completed"}
    }

    assert :ok = RPCDispatcher.route_incoming(agent_id, response)
    assert {:ok, ^response} = Task.await(original, 500)
  end

  test "pending timeout is explicit and a late response is replayed on retry" do
    agent_id = "timeout-#{System.unique_integer([:positive])}"
    request = request()
    assert :ok = AgentRegistry.register_agent(agent_id, self())
    on_exit(fn -> AgentRegistry.unregister_agent(agent_id, self()) end)

    assert {:error, :rpc_timeout} = RPCDispatcher.dispatch(agent_id, request, timeout: 10)
    assert_receive {:commander_rpc, _wire}

    response = %RPCResponse{
      protocol_version: 1,
      request_id: request.request_id,
      result: %{"status" => "late-but-authoritative"}
    }

    assert :ok = RPCDispatcher.route_incoming(agent_id, response)
    assert {:ok, ^response} = RPCDispatcher.dispatch(agent_id, request, timeout: 10)
    refute_receive {:commander_rpc, _wire}
  end

  test "accepted responses are routed and ACKs are sent through the live connection" do
    agent_id = "accepted-#{System.unique_integer([:positive])}"
    request = request()
    caller = self()
    assert :ok = AgentRegistry.register_agent(agent_id, self())
    on_exit(fn -> AgentRegistry.unregister_agent(agent_id, self()) end)

    spawn(fn ->
      send(caller, {:dispatch_result, RPCDispatcher.dispatch(agent_id, request, timeout: 500)})
    end)

    assert_receive {:commander_rpc, _wire}

    accepted = %RPCAccepted{
      protocol_version: 1,
      request_id: request.request_id,
      remote_execution_id: "00000000-0000-0000-0000-000000000098"
    }

    assert :ok = RPCDispatcher.route_incoming(agent_id, accepted)
    assert_receive {:dispatch_result, {:ok, ^accepted}}

    ack = %EventAck{
      protocol_version: 1,
      remote_execution_id: accepted.remote_execution_id,
      highest_contiguous_sequence: 12
    }

    assert :ok = RPCDispatcher.ack_event(agent_id, ack)
    assert_receive {:commander_event_ack, %{"highest_contiguous_sequence" => 12}}
  end

  test "pending requests and replay entries are kept outside the live-agent registry" do
    pending = start_supervised!({PendingRequestRegistry, name: nil})
    replay = start_supervised!({ReplayCache, name: nil, ttl_ms: 1_000})
    request_id = "00000000-0000-0000-0000-000000000011"
    response = %RPCResponse{protocol_version: 1, request_id: request_id, result: %{}}

    assert :ok = PendingRequestRegistry.register(pending, request_id, self(), 100)
    assert :ok = ReplayCache.put(replay, request_id, response)
    assert {:ok, ^response} = ReplayCache.fetch(replay, request_id)
    assert :ok = PendingRequestRegistry.complete(pending, request_id, response)
    assert_receive {:commander_rpc_result, ^request_id, ^response}
  end

  test "replay cache fails closed at capacity and admits a key only after expiry" do
    {:ok, clock} = Agent.start_link(fn -> 1_000 end)

    replay =
      start_supervised!(
        {ReplayCache, name: nil, max_entries: 1, clock: fn -> Agent.get(clock, & &1) end}
      )

    assert :ok = ReplayCache.claim(replay, :first_nonce, 100)
    assert {:error, :capacity_reached} = ReplayCache.claim(replay, :second_nonce, 100)
    assert {:ok, :claimed} = ReplayCache.fetch(replay, :first_nonce)

    Agent.update(clock, &(&1 + 101))

    assert :ok = ReplayCache.claim(replay, :second_nonce, 100)
    assert :error = ReplayCache.fetch(replay, :first_nonce)
    assert {:ok, :claimed} = ReplayCache.fetch(replay, :second_nonce)
  end

  test "a replacement replays every still-pending request after activation" do
    agent_id = "replay-#{System.unique_integer([:positive])}"
    request = request()
    caller = self()
    old = spawn(fn -> receive do: (message -> send(caller, {:old, message})) end)

    replacement =
      spawn(fn -> receive do: (message -> send(caller, {:replacement, message})) end)

    assert :ok = AgentRegistry.register_agent(agent_id, old)

    spawn(fn ->
      send(caller, {:dispatch_result, RPCDispatcher.dispatch(agent_id, request, timeout: 500)})
    end)

    assert_receive {:old, {:commander_rpc, original_wire}}, 500
    assert {:ok, _generation} = AgentRegistry.activate_agent(agent_id, replacement, %{})
    assert :ok = RPCDispatcher.replay_pending(agent_id)
    assert_receive {:replacement, {:commander_rpc, ^original_wire}}, 500
  end

  test "job events and acknowledgements are bound to the accepted execution owner" do
    agent_id = "event-owner-#{System.unique_integer([:positive])}"
    request = request()
    caller = self()
    assert :ok = AgentRegistry.register_agent(agent_id, self())
    on_exit(fn -> AgentRegistry.unregister_agent(agent_id, self()) end)
    JSON.encode!(%{})

    spawn(fn ->
      send(caller, {:dispatch_result, RPCDispatcher.dispatch(agent_id, request, timeout: 500)})
    end)

    assert_receive {:commander_rpc, _wire}, 500

    accepted = %RPCAccepted{
      protocol_version: 1,
      request_id: request.request_id,
      remote_execution_id: "00000000-0000-0000-0000-000000000099"
    }

    assert :ok = RPCDispatcher.route_incoming(agent_id, accepted)
    assert_receive {:dispatch_result, {:ok, ^accepted}}

    event = %JobEvent{
      protocol_version: 1,
      remote_execution_id: accepted.remote_execution_id,
      sequence: 1,
      event: "started",
      phase: nil,
      metadata: nil,
      occurred_at: nil
    }

    assert {:error, :agent_mismatch} = RPCDispatcher.route_incoming("spoofed-agent", event)

    ack = %EventAck{
      protocol_version: 1,
      remote_execution_id: accepted.remote_execution_id,
      highest_contiguous_sequence: 1
    }

    assert {:error, :agent_mismatch} = RPCDispatcher.ack_event("spoofed-agent", ack)
    assert :ok = RPCDispatcher.ack_event(agent_id, ack)
  end

  test "execution ownership survives long workflows and refreshes on events and acknowledgements" do
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    replay =
      start_supervised!(
        {ReplayCache, name: nil, max_entries: 10, clock: fn -> Agent.get(clock, & &1) end}
      )

    agent_id = "long-owner-#{System.unique_integer([:positive])}"
    request = request()
    assert :ok = AgentRegistry.register_agent(agent_id, self())
    on_exit(fn -> AgentRegistry.unregister_agent(agent_id, self()) end)

    original =
      Task.async(fn ->
        RPCDispatcher.dispatch(agent_id, request, timeout: 500, replay_cache: replay)
      end)

    assert_receive {:commander_rpc, _wire}, 500

    accepted = %RPCAccepted{
      protocol_version: 1,
      request_id: request.request_id,
      remote_execution_id: "00000000-0000-0000-0000-000000000097"
    }

    assert :ok = RPCDispatcher.route_incoming(agent_id, accepted, replay_cache: replay)
    assert {:ok, ^accepted} = Task.await(original, 500)

    event = %JobEvent{
      protocol_version: 1,
      remote_execution_id: accepted.remote_execution_id,
      sequence: 1,
      event: "still-running"
    }

    Agent.update(clock, fn _now -> :timer.minutes(11) end)
    assert :ok = RPCDispatcher.route_incoming(agent_id, event, replay_cache: replay)

    ack = %EventAck{
      protocol_version: 1,
      remote_execution_id: accepted.remote_execution_id,
      highest_contiguous_sequence: 1
    }

    Agent.update(clock, fn _now -> :timer.hours(24) + :timer.minutes(5) end)
    assert :ok = RPCDispatcher.ack_event(agent_id, ack, replay_cache: replay)
    assert_receive {:commander_event_ack, _wire}, 500

    Agent.update(clock, fn _now -> :timer.hours(48) end)
    assert :ok = RPCDispatcher.route_incoming(agent_id, event, replay_cache: replay)
  end

  test "losing the current control connection orphans its live PTY sessions" do
    agent_id = "orphan-#{System.unique_integer([:positive])}"
    session_id = "session-#{System.unique_integer([:positive])}"
    channel = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> PTYSessionRecord.delete(session_id) end)

    assert :ok = SessionTracker.register_session(agent_id, session_id, %{state: :running})
    assert :ok = AgentRegistry.register_agent(agent_id, channel)
    Process.exit(channel, :kill)

    assert_eventually(fn ->
      match?({:ok, %{state: :detached}}, SessionTracker.find_session(session_id))
    end)
  end

  test "same-name control replacement orphans old PTY sessions before terminal reconciliation" do
    agent_id = "replace-orphan-#{System.unique_integer([:positive])}"
    session_id = "replace-session-#{System.unique_integer([:positive])}"
    old_control = spawn(fn -> Process.sleep(:infinity) end)
    replacement_control = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      if Process.alive?(old_control), do: Process.exit(old_control, :kill)
      if Process.alive?(replacement_control), do: Process.exit(replacement_control, :kill)
      PTYSessionRecord.delete(session_id)
    end)

    assert :ok = SessionTracker.register_session(agent_id, session_id, %{state: :running})
    assert :ok = AgentRegistry.register_agent(agent_id, old_control)
    assert :ok = AgentRegistry.register_agent(agent_id, replacement_control)

    assert_eventually(fn ->
      match?({:ok, %{state: :detached}}, SessionTracker.find_session(session_id))
    end)
  end

  test "PTY dispatch telemetry excludes commands, input, environment, and working directories" do
    agent_id = "safe-dispatch-#{System.unique_integer([:positive])}"
    secret = "PTY-DISPATCH-SECRET-#{System.unique_integer([:positive])}"
    session_id = "#{secret}-session"
    expected_hash = :crypto.hash(:sha256, session_id) |> Base.encode16(case: :lower)
    handler_id = "safe-pty-dispatch-#{System.unique_integer([:positive])}"

    assert :ok = AgentRegistry.register_agent(agent_id, self())
    assert {:ok, _generation} = AgentRegistry.attach_terminal(agent_id, self(), {:legacy, self()})
    on_exit(fn -> AgentRegistry.unregister_agent(agent_id, self()) end)

    :telemetry.attach(
      handler_id,
      [:gsmlg, :log],
      fn _event, _measurements, metadata, pid -> send(pid, {:dispatch_log, metadata}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      capture_log(fn ->
        assert {:error, :dangerous_command} =
                 CommandDispatcher.create_pty(agent_id,
                   command: "rm -rf / #{secret}",
                   env_vars: %{"SECRET" => secret},
                   working_dir: "/tmp/#{secret}"
                 )

        assert_receive {:dispatch_log,
                        %{
                          message: "Potentially dangerous command detected",
                          command_code: :create_pty,
                          command_size: command_size
                        } = dangerous_metadata}

        assert command_size == byte_size("rm -rf / #{secret}")
        refute inspect(dangerous_metadata) =~ secret

        assert :ok =
                 CommandDispatcher.dispatch(agent_id, :send_input, %{
                   session_id: session_id,
                   data: secret
                 })

        assert_receive {:send_input, %{session_id: ^session_id, data: ^secret}}

        assert_receive {:dispatch_log,
                        %{
                          message: "PTY command dispatched",
                          command_type: :send_input,
                          session_id_hash: ^expected_hash,
                          session_id_size: session_id_size,
                          payload_size: payload_size
                        } = audit_metadata}

        assert session_id_size == byte_size(session_id)
        assert payload_size > 0
        refute inspect(audit_metadata) =~ secret
      end)

    refute log =~ secret
  end

  defp request do
    unique = System.unique_integer([:positive])
    suffix = unique |> Integer.to_string() |> String.pad_leading(12, "0") |> String.slice(-12, 12)

    %RPCRequest{
      protocol_version: 1,
      request_id: "00000000-0000-0000-0000-#{suffix}",
      capability: "browser.control",
      capability_version: 1,
      operation: "manager.status",
      idempotency_key: "manager-status-#{unique}",
      deadline_at: DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_iso8601(),
      payload: %{}
    }
  end

  defp assert_eventually(fun, attempts \\ 40)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
