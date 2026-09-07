defmodule GSMLG.Commander.RPCRouterTest do
  use ExUnit.Case, async: true

  alias GSMLG.Commander.{CapabilityRegistry, RequestDedup, RPCRouter}
  alias GSMLG.Commander.Protocol.{Capability, RPCAccepted, RPCError, RPCRequest, RPCResponse}

  defmodule SlowHandler do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call({:rpc, request}, _from, opts) do
      Process.sleep(Keyword.fetch!(opts, :delay_ms))
      send(Keyword.fetch!(opts, :test_pid), {:slow_handler_finished, request.request_id})
      {:reply, {:ok, %{"ok" => true}}, opts}
    end
  end

  test "routes supported operations and replays completed results" do
    registry = start_supervised!({CapabilityRegistry, name: nil})
    dedup = start_supervised!({RequestDedup, name: nil})
    test_pid = self()

    handler = fn request ->
      send(test_pid, {:handled, request.request_id})
      {:ok, %{"ok" => true}}
    end

    assert :ok = CapabilityRegistry.register(registry, descriptor(), handler)
    request = request()

    assert {:ok, %RPCResponse{request_id: request_id, result: %{"ok" => true}} = response} =
             RPCRouter.route(request, registry: registry, request_dedup: dedup)

    assert request_id == request.request_id
    assert_receive {:handled, ^request_id}

    assert {:ok, ^response} = RPCRouter.route(request, registry: registry, request_dedup: dedup)
    refute_receive {:handled, ^request_id}
  end

  test "re-correlates an idempotency replay to a new request ID" do
    registry = start_supervised!({CapabilityRegistry, name: nil})
    dedup = start_supervised!({RequestDedup, name: nil})
    test_pid = self()

    assert :ok =
             CapabilityRegistry.register(registry, descriptor(), fn request ->
               send(test_pid, {:handled, request.request_id})
               {:ok, %{"ok" => true}}
             end)

    original = request()
    replay_request = %{original | request_id: "00000000-0000-0000-0000-000000000002"}

    assert {:ok, %RPCResponse{request_id: original_id}} =
             RPCRouter.route(original, registry: registry, request_dedup: dedup)

    assert {:ok, %RPCResponse{request_id: replay_id, result: %{"ok" => true}}} =
             RPCRouter.route(replay_request, registry: registry, request_dedup: dedup)

    assert original_id == original.request_id
    assert replay_id == replay_request.request_id
    assert_receive {:handled, ^original_id}
    refute_receive {:handled, ^replay_id}
  end

  test "returns accepted for a long-running operation" do
    registry = start_supervised!({CapabilityRegistry, name: nil})
    dedup = start_supervised!({RequestDedup, name: nil})
    execution_id = "00000000-0000-0000-0000-000000000099"

    assert :ok =
             CapabilityRegistry.register(registry, descriptor(), fn _request ->
               {:accepted, execution_id}
             end)

    assert {:ok, %RPCAccepted{remote_execution_id: ^execution_id}} =
             RPCRouter.route(request(), registry: registry, request_dedup: dedup)
  end

  @tag timeout: 8_000
  test "a valid browser action can exceed the default GenServer call timeout" do
    registry = start_supervised!({CapabilityRegistry, name: nil})
    dedup = start_supervised!({RequestDedup, name: nil})

    handler =
      start_supervised!({SlowHandler, test_pid: self(), delay_ms: 5_100})

    assert :ok = CapabilityRegistry.register(registry, descriptor("session.act"), handler)
    request = action_request(DateTime.utc_now() |> DateTime.add(7, :second))

    assert {:ok, %RPCResponse{result: %{"ok" => true}}} =
             RPCRouter.route(request, registry: registry, request_dedup: dedup)

    assert_receive {:slow_handler_finished, request_id}
    assert request_id == request.request_id
  end

  test "deadline timeout is an ambiguous mutation outcome while the handler finishes" do
    registry = start_supervised!({CapabilityRegistry, name: nil})
    dedup = start_supervised!({RequestDedup, name: nil})
    handler = start_supervised!({SlowHandler, test_pid: self(), delay_ms: 250})

    assert :ok = CapabilityRegistry.register(registry, descriptor("session.act"), handler)
    request = action_request(DateTime.utc_now() |> DateTime.add(150, :millisecond))

    assert {:error,
            %RPCError{
              code: "operation_outcome_unknown",
              retryable: false,
              human_action: "reconcile"
            }} = RPCRouter.route(request, registry: registry, request_dedup: dedup)

    assert_receive {:slow_handler_finished, request_id}, 500
    assert request_id == request.request_id
  end

  test "bounds function capability handlers by the same mutation deadline" do
    registry = start_supervised!({CapabilityRegistry, name: nil})
    dedup = start_supervised!({RequestDedup, name: nil})
    test_pid = self()

    assert :ok =
             CapabilityRegistry.register(registry, descriptor("session.act"), fn request ->
               Process.sleep(250)
               send(test_pid, {:function_handler_finished, request.request_id})
               {:ok, %{"ok" => true}}
             end)

    request = action_request(DateTime.utc_now() |> DateTime.add(150, :millisecond))

    assert {:error,
            %RPCError{
              code: "operation_outcome_unknown",
              retryable: false,
              human_action: "reconcile"
            }} = RPCRouter.route(request, registry: registry, request_dedup: dedup)

    refute_receive {:function_handler_finished, _request_id}, 300
  end

  test "does not dispatch an RPC whose absolute deadline expires while queued" do
    registry = start_supervised!({CapabilityRegistry, name: nil})
    dedup = start_supervised!({RequestDedup, name: nil})
    counter = start_supervised!({Agent, fn -> 0 end})

    assert :ok =
             CapabilityRegistry.register(registry, descriptor("session.act"), fn _request ->
               Agent.update(counter, &(&1 + 1))
               {:ok, %{"ok" => true}}
             end)

    :sys.suspend(dedup)
    on_exit(fn -> if Process.alive?(dedup), do: :sys.resume(dedup) end)

    request = action_request(DateTime.utc_now() |> DateTime.add(50, :millisecond))

    task =
      Task.async(fn -> RPCRouter.route(request, registry: registry, request_dedup: dedup) end)

    Process.sleep(75)
    :sys.resume(dedup)

    assert {:error, %RPCError{code: "deadline_exceeded", retryable: false}} =
             Task.await(task)

    assert Agent.get(counter, & &1) == 0
  end

  test "turns a capability handler crash into a replayable RPC error" do
    registry = start_supervised!({CapabilityRegistry, name: nil})
    dedup = start_supervised!({RequestDedup, name: nil})
    counter = start_supervised!({Agent, fn -> 0 end})

    assert :ok =
             CapabilityRegistry.register(registry, descriptor(), fn _request ->
               Agent.update(counter, &(&1 + 1))
               raise "secret handler state"
             end)

    request = request()

    assert {:error, %{code: "capability_handler_failed", details: %{}} = first_error} =
             RPCRouter.route(request, registry: registry, request_dedup: dedup)

    assert {:error, ^first_error} =
             RPCRouter.route(request, registry: registry, request_dedup: dedup)

    assert Agent.get(counter, & &1) == 1
    refute inspect(first_error) =~ "secret handler state"
  end

  test "rejects operations not advertised by the registered descriptor" do
    registry = start_supervised!({CapabilityRegistry, name: nil})
    dedup = start_supervised!({RequestDedup, name: nil})
    assert :ok = CapabilityRegistry.register(registry, descriptor(), fn _ -> {:ok, %{}} end)

    request = %{request() | operation: "profiles.list"}

    assert {:error, %{code: "operation_not_advertised"}} =
             RPCRouter.route(request, registry: registry, request_dedup: dedup)
  end

  defp descriptor(operation \\ "manager.status") do
    %Capability{
      id: "browser.control",
      version: 1,
      backend: "cloakbrowser",
      operations: [operation],
      limits: %{},
      workflows: []
    }
  end

  defp action_request(deadline) do
    %RPCRequest{
      protocol_version: 1,
      request_id: "00000000-0000-0000-0000-000000000011",
      capability: "browser.control",
      capability_version: 1,
      operation: "session.act",
      idempotency_key: "action-deadline",
      deadline_at: DateTime.to_iso8601(deadline),
      payload: %{
        "session_id" => "session-1",
        "action" => %{"timeout_ms" => 6_000}
      }
    }
  end

  defp request do
    %RPCRequest{
      protocol_version: 1,
      request_id: "00000000-0000-0000-0000-000000000001",
      capability: "browser.control",
      capability_version: 1,
      operation: "manager.status",
      idempotency_key: "manager-status",
      deadline_at: DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_iso8601(),
      payload: %{}
    }
  end
end
