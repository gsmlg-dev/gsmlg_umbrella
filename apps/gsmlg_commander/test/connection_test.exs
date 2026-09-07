defmodule GSMLG.Commander.ConnectionTest do
  use ExUnit.Case, async: true

  alias GSMLG.Commander.{CapabilityRegistry, Connection, RequestDedup, RPCRouter}
  alias GSMLG.Commander.Protocol.Capability

  test "owns the generic channel and publishes capability snapshots" do
    registry = start_supervised!({CapabilityRegistry, name: nil})
    dedup = start_supervised!({RequestDedup, name: nil})
    test_pid = self()

    assert :ok = CapabilityRegistry.register(registry, descriptor(), fn _ -> {:ok, %{}} end)

    connection =
      start_supervised!(
        {Connection,
         socket: :commander_socket,
         commander_name: "node-a",
         capability_registry: registry,
         request_dedup: dedup,
         join_fun: fn socket, topic ->
           send(test_pid, {:join, socket, topic})
           {:ok, %{}, :control_channel}
         end,
         push_fun: fn channel, event, payload ->
           send(test_pid, {:push, channel, event, payload})
           :ok
         end,
         tls_summary_fun: fn ->
           %{
             "status" => "verified",
             "certificate_expires_at" => "2026-10-06T00:00:00Z"
           }
         end,
         heartbeat_interval: 60_000,
         name: nil}
      )

    assert_receive {:join, :commander_socket, "commander:node-a"}

    assert_receive {:push, :control_channel, "message",
                    %{
                      "type" => "version.negotiation",
                      "protocol_version" => 1,
                      "capabilities" => [%{"id" => "browser.control"}]
                    }}

    assert_receive {:push, :control_channel, "message",
                    %{
                      "type" => "heartbeat",
                      "tls" => %{
                        "status" => "verified",
                        "certificate_expires_at" => "2026-10-06T00:00:00Z"
                      }
                    }}

    assert Process.alive?(connection)
  end

  test "publishes runtime register and unregister as capability updates, not renegotiation" do
    registry = start_supervised!({CapabilityRegistry, name: nil})
    dedup = start_supervised!({RequestDedup, name: nil})
    test_pid = self()

    start_supervised!(
      {Connection,
       socket: :commander_socket,
       commander_name: "node-runtime-capabilities",
       capability_registry: registry,
       request_dedup: dedup,
       join_fun: fn _, _ -> {:ok, %{}, :control_channel} end,
       push_fun: fn channel, event, payload ->
         send(test_pid, {:push, channel, event, payload})
         :ok
       end,
       heartbeat_interval: 60_000,
       name: nil}
    )

    assert_receive {:push, :control_channel, "message",
                    %{"type" => "version.negotiation", "capabilities" => []}}

    assert :ok = CapabilityRegistry.register(registry, descriptor(), fn _ -> {:ok, %{}} end)

    assert_receive {:push, :control_channel, "message",
                    %{
                      "type" => "capabilities.update",
                      "capabilities" => [%{"id" => "browser.control"}]
                    }}

    assert :ok = CapabilityRegistry.unregister(registry, "browser.control")

    assert_receive {:push, :control_channel, "message",
                    %{"type" => "capabilities.update", "capabilities" => []}}

    refute_receive {:push, :control_channel, "message", %{"type" => "version.negotiation"}}, 50
  end

  test "normalizes invalid control payload telemetry without retaining attacker values" do
    registry = start_supervised!({CapabilityRegistry, name: nil})
    dedup = start_supervised!({RequestDedup, name: nil})
    sentinel = "CONTROL-TYPE-SECRET-#{System.unique_integer([:positive])}"
    handler_id = "connection-invalid-payload-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:gsmlg, :log],
      fn _event, _measurements, metadata, pid -> send(pid, {:control_log, metadata}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    connection =
      start_supervised!(
        {Connection,
         socket: :commander_socket,
         commander_name: "node-safe-telemetry",
         capability_registry: registry,
         request_dedup: dedup,
         join_fun: fn _, _ -> {:ok, %{}, :control_channel} end,
         push_fun: fn _, _, _ -> :ok end,
         heartbeat_interval: 60_000,
         name: nil}
      )

    send(connection, %{"type" => sentinel, "nested" => %{"prompt" => sentinel}})

    assert_receive {:control_log,
                    %{
                      message: "Invalid Commander control message",
                      message_code: :unknown,
                      payload_size: payload_size
                    } = metadata}

    assert payload_size > 0
    refute Map.has_key?(metadata, :message_type)
    refute inspect(metadata) =~ sentinel
  end

  test "routes RPC without exposing the request payload in telemetry" do
    registry = start_supervised!({CapabilityRegistry, name: nil})
    dedup = start_supervised!({RequestDedup, name: nil})
    test_pid = self()

    assert :ok =
             CapabilityRegistry.register(registry, descriptor(), fn request ->
               send(test_pid, {:handled, request.request_id})
               {:ok, %{"status" => "healthy"}}
             end)

    handler_id = "connection-safe-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:gsmlg, :commander, :rpc, :request],
      fn event, measurements, metadata, pid -> send(pid, {event, measurements, metadata}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    connection =
      start_supervised!(
        {Connection,
         socket: :commander_socket,
         commander_name: "node-a",
         capability_registry: registry,
         request_dedup: dedup,
         join_fun: fn _, _ -> {:ok, %{}, :control_channel} end,
         push_fun: fn channel, event, payload ->
           send(test_pid, {:push, channel, event, payload})
           :ok
         end,
         heartbeat_interval: 60_000,
         name: nil}
      )

    secret = "PROMPT-CONTENT-MUST-NOT-LEAK"
    # The dependency's default channel forwards payload maps directly to its join caller.
    send(connection, request_wire(secret))

    assert_receive {:handled, "00000000-0000-0000-0000-000000000001"}
    assert_receive {:push, :control_channel, "message", %{"type" => "rpc.response"}}

    assert_receive {[:gsmlg, :commander, :rpc, :request], %{payload_size: size}, metadata}
    assert size > 0
    refute inspect(metadata) =~ secret

    assert Map.keys(metadata) |> Enum.sort() == [
             :capability,
             :commander_id,
             :operation,
             :request_id
           ]
  end

  test "a slow capability RPC does not block control-channel heartbeats" do
    registry = start_supervised!({CapabilityRegistry, name: nil})
    dedup = start_supervised!({RequestDedup, name: nil})
    rpc_tasks = start_supervised!({Task.Supervisor, name: nil})
    test_pid = self()

    assert :ok =
             CapabilityRegistry.register(registry, descriptor(), fn request ->
               send(test_pid, {:rpc_started, self(), request.request_id})

               receive do
                 :finish_rpc -> {:ok, %{"status" => "healthy"}}
               end
             end)

    connection =
      start_supervised!(
        {Connection,
         socket: :commander_socket,
         commander_name: "node-nonblocking-rpc",
         capability_registry: registry,
         request_dedup: dedup,
         rpc_task_supervisor: rpc_tasks,
         join_fun: fn _, _ -> {:ok, %{}, :control_channel} end,
         push_fun: fn channel, event, payload ->
           send(test_pid, {:push, channel, event, payload})
           :ok
         end,
         heartbeat_interval: 60_000,
         name: nil}
      )

    assert_receive {:push, :control_channel, "message", %{"type" => "version.negotiation"}}
    send(connection, request_wire("slow-rpc"))
    assert_receive {:rpc_started, rpc_pid, _request_id}
    on_exit(fn -> send(rpc_pid, :finish_rpc) end)

    send(connection, :heartbeat)
    assert_receive {:push, :control_channel, "message", %{"type" => "heartbeat"}}, 100

    send(rpc_pid, :finish_rpc)
    assert_receive {:push, :control_channel, "message", %{"type" => "rpc.response"}}, 500
  end

  test "heartbeats advertise only the current bounded TLS summary" do
    registry = start_supervised!({CapabilityRegistry, name: nil})
    dedup = start_supervised!({RequestDedup, name: nil})
    test_pid = self()

    connection =
      start_supervised!(
        {Connection,
         socket: :commander_socket,
         commander_name: "node-tls-summary",
         capability_registry: registry,
         request_dedup: dedup,
         join_fun: fn _, _ -> {:ok, %{}, :control_channel} end,
         push_fun: fn channel, event, payload ->
           send(test_pid, {:push, channel, event, payload})
           :ok
         end,
         tls_summary_fun: fn ->
           %{
             "status" => "verified",
             "certificate_expires_at" => "2026-10-06T00:00:00Z"
           }
         end,
         heartbeat_interval: 60_000,
         name: nil}
      )

    assert_receive {:push, :control_channel, "message", %{"type" => "version.negotiation"}}
    send(connection, :heartbeat)

    assert_receive {:push, :control_channel, "message",
                    %{
                      "type" => "heartbeat",
                      "tls" => %{
                        "status" => "verified",
                        "certificate_expires_at" => "2026-10-06T00:00:00Z"
                      }
                    }}
  end

  test "bounds unique RPC flooding and leaves overloaded requests retryable" do
    registry = start_supervised!({CapabilityRegistry, name: nil})
    dedup = start_supervised!({RequestDedup, name: nil})
    rpc_tasks = start_supervised!({Task.Supervisor, name: nil})
    test_pid = self()

    assert :ok =
             CapabilityRegistry.register(registry, descriptor(), fn request ->
               send(test_pid, {:rpc_started, self(), request.request_id})

               receive do
                 :finish_rpc -> {:ok, %{"status" => "healthy"}}
               end
             end)

    connection =
      start_supervised!(
        {Connection,
         socket: :commander_socket,
         commander_name: "node-bounded-rpc",
         capability_registry: registry,
         request_dedup: dedup,
         rpc_task_supervisor: rpc_tasks,
         max_in_flight_rpcs: 1,
         join_fun: fn _, _ -> {:ok, %{}, :control_channel} end,
         push_fun: fn channel, event, payload ->
           send(test_pid, {:push, channel, event, payload})
           :ok
         end,
         heartbeat_interval: 60_000,
         name: nil}
      )

    assert_receive {:push, :control_channel, "message", %{"type" => "version.negotiation"}}

    first =
      request_wire("first",
        request_id: "00000000-0000-0000-0000-000000000011",
        idempotency_key: "bounded-first"
      )

    second =
      request_wire("second",
        request_id: "00000000-0000-0000-0000-000000000012",
        idempotency_key: "bounded-second"
      )

    overflow =
      [second] ++
        for index <- 13..20 do
          suffix = index |> Integer.to_string() |> String.pad_leading(12, "0")

          request_wire("overflow-#{index}",
            request_id: "00000000-0000-0000-0000-#{suffix}",
            idempotency_key: "bounded-overflow-#{index}"
          )
        end

    send(connection, first)
    assert_receive {:rpc_started, first_pid, "00000000-0000-0000-0000-000000000011"}

    Enum.each(overflow, &send(connection, &1))

    for request <- overflow do
      assert_receive {:push, :control_channel, "message",
                      %{
                        "type" => "rpc.error",
                        "request_id" => request_id,
                        "code" => "overloaded",
                        "retryable" => true,
                        "details" => %{"max_in_flight" => 1}
                      }}

      assert request_id == request["request_id"]
    end

    refute_receive {:rpc_started, _, _}, 50

    send(connection, first)

    assert_receive {:push, :control_channel, "message",
                    %{
                      "type" => "rpc.error",
                      "request_id" => "00000000-0000-0000-0000-000000000011",
                      "code" => "request_in_progress",
                      "retryable" => true
                    }}

    refute_receive {:rpc_started, _, "00000000-0000-0000-0000-000000000011"}, 50

    send(first_pid, :finish_rpc)

    assert_receive {:push, :control_channel, "message",
                    %{
                      "type" => "rpc.response",
                      "request_id" => "00000000-0000-0000-0000-000000000011"
                    }}

    send(connection, second)
    assert_receive {:rpc_started, second_pid, "00000000-0000-0000-0000-000000000012"}
    send(second_pid, :finish_rpc)

    assert_receive {:push, :control_channel, "message",
                    %{
                      "type" => "rpc.response",
                      "request_id" => "00000000-0000-0000-0000-000000000012"
                    }}
  end

  test "replays completed duplicates while a unique RPC occupies the admission slot" do
    registry = start_supervised!({CapabilityRegistry, name: nil})
    dedup = start_supervised!({RequestDedup, name: nil})
    rpc_tasks = start_supervised!({Task.Supervisor, name: nil})
    test_pid = self()

    assert :ok =
             CapabilityRegistry.register(registry, descriptor(), fn request ->
               send(test_pid, {:rpc_started, self(), request.request_id})

               receive do
                 :finish_rpc -> {:ok, %{"status" => request.payload["input"]["prompt"]}}
               end
             end)

    connection =
      start_supervised!(
        {Connection,
         socket: :commander_socket,
         commander_name: "node-replay-at-capacity",
         capability_registry: registry,
         request_dedup: dedup,
         rpc_task_supervisor: rpc_tasks,
         max_in_flight_rpcs: 1,
         join_fun: fn _, _ -> {:ok, %{}, :control_channel} end,
         push_fun: fn channel, event, payload ->
           send(test_pid, {:push, channel, event, payload})
           :ok
         end,
         heartbeat_interval: 60_000,
         name: nil}
      )

    assert_receive {:push, :control_channel, "message", %{"type" => "version.negotiation"}}

    completed =
      request_wire("completed",
        request_id: "00000000-0000-0000-0000-000000000021",
        idempotency_key: "completed-replay"
      )

    send(connection, completed)
    assert_receive {:rpc_started, completed_pid, "00000000-0000-0000-0000-000000000021"}
    send(completed_pid, :finish_rpc)
    assert_receive {:push, :control_channel, "message", %{"type" => "rpc.response"}}

    occupying =
      request_wire("occupying",
        request_id: "00000000-0000-0000-0000-000000000022",
        idempotency_key: "occupying-slot"
      )

    send(connection, occupying)
    assert_receive {:rpc_started, occupying_pid, "00000000-0000-0000-0000-000000000022"}

    replay =
      request_wire("completed",
        request_id: "00000000-0000-0000-0000-000000000023",
        idempotency_key: "completed-replay"
      )

    send(connection, replay)

    assert_receive {:push, :control_channel, "message",
                    %{
                      "type" => "rpc.response",
                      "request_id" => "00000000-0000-0000-0000-000000000023",
                      "result" => %{"status" => "completed"}
                    }}

    refute_receive {:rpc_started, _, "00000000-0000-0000-0000-000000000023"}, 50
    send(occupying_pid, :finish_rpc)
    assert_receive {:push, :control_channel, "message", %{"type" => "rpc.response"}}
  end

  test "releases admission after an RPC task crashes" do
    registry = start_supervised!({CapabilityRegistry, name: nil})
    dedup = start_supervised!({RequestDedup, name: nil})
    rpc_tasks = start_supervised!({Task.Supervisor, name: nil})
    route_attempt = start_supervised!({Agent, fn -> 0 end})
    test_pid = self()

    assert :ok =
             CapabilityRegistry.register(registry, descriptor(), fn request ->
               send(test_pid, {:handled_after_crash, request.request_id})
               {:ok, %{"status" => "healthy"}}
             end)

    route_fun = fn request, opts ->
      case Agent.get_and_update(route_attempt, &{&1, &1 + 1}) do
        0 -> Process.exit(self(), :kill)
        _later -> RPCRouter.route(request, opts)
      end
    end

    connection =
      start_supervised!(
        {Connection,
         socket: :commander_socket,
         commander_name: "node-rpc-crash",
         capability_registry: registry,
         request_dedup: dedup,
         rpc_task_supervisor: rpc_tasks,
         rpc_route_fun: route_fun,
         max_in_flight_rpcs: 1,
         join_fun: fn _, _ -> {:ok, %{}, :control_channel} end,
         push_fun: fn channel, event, payload ->
           send(test_pid, {:push, channel, event, payload})
           :ok
         end,
         heartbeat_interval: 60_000,
         name: nil}
      )

    assert_receive {:push, :control_channel, "message", %{"type" => "version.negotiation"}}

    send(
      connection,
      request_wire("crash",
        request_id: "00000000-0000-0000-0000-000000000031",
        idempotency_key: "crashing-route"
      )
    )

    assert_receive {:push, :control_channel, "message",
                    %{
                      "type" => "rpc.error",
                      "request_id" => "00000000-0000-0000-0000-000000000031",
                      "code" => "capability_handler_failed",
                      "retryable" => true
                    }}

    send(
      connection,
      request_wire("after-crash",
        request_id: "00000000-0000-0000-0000-000000000032",
        idempotency_key: "after-crash"
      )
    )

    assert_receive {:handled_after_crash, "00000000-0000-0000-0000-000000000032"}

    assert_receive {:push, :control_channel, "message",
                    %{
                      "type" => "rpc.response",
                      "request_id" => "00000000-0000-0000-0000-000000000032"
                    }}
  end

  test "drops stale-generation results and releases their admission slot" do
    registry = start_supervised!({CapabilityRegistry, name: nil})
    dedup = start_supervised!({RequestDedup, name: nil})
    rpc_tasks = start_supervised!({Task.Supervisor, name: nil})
    join_count = start_supervised!({Agent, fn -> 0 end})
    test_pid = self()

    assert :ok =
             CapabilityRegistry.register(registry, descriptor(), fn request ->
               send(test_pid, {:rpc_started, self(), request.request_id})

               receive do
                 :finish_rpc -> {:ok, %{"status" => "healthy"}}
               end
             end)

    join_fun = fn _, _ ->
      generation = Agent.get_and_update(join_count, &{&1 + 1, &1 + 1})
      channel = {:control_channel, generation}
      send(test_pid, {:joined, channel})
      {:ok, %{}, channel}
    end

    connection =
      start_supervised!(
        {Connection,
         socket: :commander_socket,
         commander_name: "node-stale-rpc",
         capability_registry: registry,
         request_dedup: dedup,
         rpc_task_supervisor: rpc_tasks,
         max_in_flight_rpcs: 1,
         join_fun: join_fun,
         push_fun: fn channel, event, payload ->
           send(test_pid, {:push, channel, event, payload})
           :ok
         end,
         heartbeat_interval: 60_000,
         reconnect_after: 5,
         name: nil}
      )

    assert_receive {:joined, {:control_channel, 1}}
    assert_receive {:push, {:control_channel, 1}, "message", %{"type" => "version.negotiation"}}

    stale =
      request_wire("stale",
        request_id: "00000000-0000-0000-0000-000000000041",
        idempotency_key: "stale-generation"
      )

    send(connection, stale)
    assert_receive {:rpc_started, stale_pid, "00000000-0000-0000-0000-000000000041"}

    send(connection, {:phoenix_channel_leave, :reconnect})
    assert_receive {:joined, {:control_channel, 2}}, 100
    assert_receive {:push, {:control_channel, 2}, "message", %{"type" => "version.negotiation"}}

    send(stale_pid, :finish_rpc)

    refute_receive {:push, {:control_channel, 2}, "message",
                    %{
                      "type" => "rpc.response",
                      "request_id" => "00000000-0000-0000-0000-000000000041"
                    }},
                   50

    refute_receive {:push, {:control_channel, 2}, "message",
                    %{
                      "type" => "rpc.error",
                      "request_id" => "00000000-0000-0000-0000-000000000041"
                    }},
                   50

    fresh =
      request_wire("fresh",
        request_id: "00000000-0000-0000-0000-000000000042",
        idempotency_key: "fresh-generation"
      )

    send(connection, fresh)
    assert_receive {:rpc_started, fresh_pid, "00000000-0000-0000-0000-000000000042"}
    send(fresh_pid, :finish_rpc)

    assert_receive {:push, {:control_channel, 2}, "message",
                    %{
                      "type" => "rpc.response",
                      "request_id" => "00000000-0000-0000-0000-000000000042"
                    }}
  end

  test "routes cumulative event acknowledgement to capability handlers" do
    registry = start_supervised!({CapabilityRegistry, name: nil})
    dedup = start_supervised!({RequestDedup, name: nil})
    test_pid = self()

    assert :ok =
             CapabilityRegistry.register(registry, descriptor(), fn
               {:event_ack, ack} ->
                 send(test_pid, {:event_ack, ack})
                 :ok

               _request ->
                 {:accepted, "00000000-0000-0000-0000-000000000099"}
             end)

    connection =
      start_supervised!(
        {Connection,
         socket: :commander_socket,
         commander_name: "node-a",
         capability_registry: registry,
         request_dedup: dedup,
         join_fun: fn _, _ -> {:ok, %{}, :control_channel} end,
         push_fun: fn _, _, _ -> :ok end,
         heartbeat_interval: 60_000,
         name: nil}
      )

    send(connection, request_wire("bind-ack-owner"))

    assert_eventually(fn ->
      RequestDedup.execution_capability(
        dedup,
        "00000000-0000-0000-0000-000000000099"
      ) == {:ok, "browser.control"}
    end)

    send(connection, {
      :phoenix_channel_message,
      "message",
      %{
        "type" => "event.ack",
        "protocol_version" => 1,
        "remote_execution_id" => "00000000-0000-0000-0000-000000000099",
        "highest_contiguous_sequence" => 7
      }
    })

    assert_receive {:event_ack, %{highest_contiguous_sequence: 7}}, 500
  end

  test "routes event acknowledgement only to the capability that owns the execution" do
    registry = start_supervised!({CapabilityRegistry, name: nil})
    dedup = start_supervised!({RequestDedup, name: nil})
    test_pid = self()

    assert :ok =
             CapabilityRegistry.register(registry, descriptor(), fn
               {:event_ack, _ack} -> send(test_pid, :browser_ack)
               _request -> {:accepted, "00000000-0000-0000-0000-000000000099"}
             end)

    pty = GSMLG.Commander.PTYCapability.descriptor()

    assert :ok =
             CapabilityRegistry.register(registry, pty, fn {:event_ack, _ack} ->
               send(test_pid, :pty_ack)
             end)

    connection =
      start_supervised!(
        {Connection,
         socket: :commander_socket,
         commander_name: "node-a",
         capability_registry: registry,
         request_dedup: dedup,
         join_fun: fn _, _ -> {:ok, %{}, :control_channel} end,
         push_fun: fn _, _, _ -> :ok end,
         heartbeat_interval: 60_000,
         name: nil}
      )

    send(connection, request_wire("owner"))

    assert_eventually(fn ->
      RequestDedup.execution_capability(
        dedup,
        "00000000-0000-0000-0000-000000000099"
      ) == {:ok, "browser.control"}
    end)

    send(connection, {
      :phoenix_channel_message,
      "message",
      %{
        "type" => "event.ack",
        "protocol_version" => 1,
        "remote_execution_id" => "00000000-0000-0000-0000-000000000099",
        "highest_contiguous_sequence" => 7
      }
    })

    assert_receive :browser_ack, 500
    refute_receive :pty_ack
  end

  test "rejoins after the dependency terminates the channel on socket reconnect" do
    registry = start_supervised!({CapabilityRegistry, name: nil})
    dedup = start_supervised!({RequestDedup, name: nil})
    test_pid = self()

    join_fun = fn _socket, topic ->
      channel = spawn(fn -> Process.sleep(:infinity) end)
      send(test_pid, {:joined_channel, topic, channel})
      {:ok, %{}, channel}
    end

    start_supervised!(
      {Connection,
       socket: :commander_socket,
       commander_name: "node-a",
       capability_registry: registry,
       request_dedup: dedup,
       join_fun: join_fun,
       push_fun: fn _, _, _ -> :ok end,
       heartbeat_interval: 60_000,
       reconnect_after: 10,
       name: nil}
    )

    assert_receive {:joined_channel, "commander:node-a", first_channel}
    Process.exit(first_channel, :kill)
    assert_receive {:joined_channel, "commander:node-a", replacement}, 100
    assert replacement != first_channel
  end

  defp descriptor do
    %Capability{
      id: "browser.control",
      version: 1,
      backend: "cloakbrowser",
      operations: ["workflow.start"],
      limits: %{"max_sessions" => 1},
      workflows: []
    }
  end

  defp request_wire(secret, opts \\ []) do
    %{
      "type" => "rpc.request",
      "protocol_version" => 1,
      "request_id" => Keyword.get(opts, :request_id, "00000000-0000-0000-0000-000000000001"),
      "capability" => "browser.control",
      "capability_version" => 1,
      "operation" => "workflow.start",
      "idempotency_key" => Keyword.get(opts, :idempotency_key, "workflow-start"),
      "deadline_at" => DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_iso8601(),
      "payload" => %{
        "central_job_id" => "00000000-0000-0000-0000-000000000100",
        "workflow" => "gemini.deep_research",
        "workflow_version" => 1,
        "profile_id" => "profile-e2e",
        "input" => %{
          "prompt" => secret,
          "output_locale" => "en",
          "research_scope" => "public web",
          "required_sections" => ["Summary"],
          "auto_approve_plan" => true
        },
        "output_formats" => ["report.markdown", "report.json", "sources.json"],
        "requested_by_actor_id" => "actor-e2e"
      }
    }
  end

  defp assert_eventually(fun, attempts \\ 20)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(fun, attempts - 1)
    end
  end
end
