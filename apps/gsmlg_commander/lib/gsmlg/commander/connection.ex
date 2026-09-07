defmodule GSMLG.Commander.Connection do
  @moduledoc """
  Owns the generic `commander:<name>` control channel on a remote Commander.

  PTY bytes continue to use `GSMLG.Commander.Terminal`; registration, capability
  snapshots, heartbeats, capability RPC, and event acknowledgements use this process.
  """

  use GenServer

  alias GSMLG.Commander.{CapabilityRegistry, RPCRouter, RequestDedup}

  alias GSMLG.Commander.Protocol.{
    CapabilitiesUpdate,
    Envelope,
    EventAck,
    RPCRequest,
    TLSSummary,
    VersionNegotiation
  }

  alias Phoenix.SocketClient.Message

  @heartbeat_interval 30_000
  @reconnect_after 1_000
  @default_max_in_flight_rpcs 2

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def push(envelope, server \\ __MODULE__), do: GenServer.call(server, {:push, envelope})

  @impl true
  def init(opts) do
    registry = Keyword.get(opts, :capability_registry, CapabilityRegistry)
    :ok = CapabilityRegistry.subscribe(registry)

    state = %{
      socket: Keyword.fetch!(opts, :socket),
      topic: "commander:#{Keyword.fetch!(opts, :commander_name)}",
      commander_name: Keyword.fetch!(opts, :commander_name),
      channel: nil,
      channel_ref: nil,
      capability_registry: registry,
      request_dedup: Keyword.get(opts, :request_dedup, GSMLG.Commander.RequestDedup),
      rpc_task_supervisor: Keyword.get(opts, :rpc_task_supervisor),
      rpc_route_fun: Keyword.get(opts, :rpc_route_fun, &RPCRouter.route/2),
      max_in_flight_rpcs: Keyword.get(opts, :max_in_flight_rpcs, @default_max_in_flight_rpcs),
      rpc_tasks: %{},
      join_fun: Keyword.get(opts, :join_fun, &Phoenix.SocketClient.Channel.join/2),
      push_fun: Keyword.get(opts, :push_fun, &Phoenix.SocketClient.Channel.push_async/3),
      heartbeat_interval: Keyword.get(opts, :heartbeat_interval, @heartbeat_interval),
      reconnect_after: Keyword.get(opts, :reconnect_after, @reconnect_after),
      tls_summary_fun: Keyword.get(opts, :tls_summary_fun, fn -> %{"status" => "invalid"} end),
      heartbeat_timer: nil,
      initial_capabilities_sent: false,
      channel_generation: 0
    }

    {:ok, join_control(state)}
  end

  @impl true
  def handle_call({:push, envelope}, _from, state) do
    {:reply, send_envelope(envelope, state), state}
  end

  @impl true
  def handle_info({:phoenix_channel_join, {:ok, _response}}, state) do
    {:noreply,
     state |> send_initial_capabilities() |> send_current_heartbeat() |> schedule_heartbeat()}
  end

  def handle_info({:phoenix_channel_join, {:error, reason}}, state) do
    log_transport_failure("Commander control channel join failed", state, reason)
    {:noreply, schedule_reconnect(state)}
  end

  def handle_info({:phoenix_channel_message, "message", payload}, state) do
    handle_payload(payload, state)
  end

  def handle_info(%Message{event: "message", payload: payload}, state) do
    handle_payload(payload, state)
  end

  def handle_info(%{"type" => _type} = payload, state) do
    handle_payload(payload, state)
  end

  def handle_info({:phoenix_channel_leave, reason}, state) do
    log_transport_failure("Commander control channel left", state, reason)

    {:noreply,
     state
     |> cancel_heartbeat()
     |> clear_channel()
     |> schedule_reconnect()}
  end

  def handle_info(
        {:DOWN, ref, :process, channel, reason},
        %{channel_ref: ref, channel: channel} = state
      ) do
    log_transport_failure("Commander control channel process stopped", state, reason)

    {:noreply,
     state
     |> cancel_heartbeat()
     |> Map.put(:channel, nil)
     |> Map.put(:channel_ref, nil)
     |> schedule_reconnect()}
  end

  def handle_info({:DOWN, monitor_ref, :process, task_pid, _reason}, state) do
    case pop_rpc_task_by_monitor(state, monitor_ref, task_pid) do
      {:ok, task, state} ->
        if current_rpc_generation?(task, state) do
          request_result = RPCRouter.task_failure(task.request)
          send_rpc_result(request_result, state)
        end

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:commander_capabilities_changed, descriptors}, state) do
    {:noreply, send_capability_update(descriptors, state)}
  end

  def handle_info(:heartbeat, state) do
    {:noreply, state |> send_current_heartbeat() |> schedule_heartbeat()}
  end

  def handle_info(:reconnect, state), do: {:noreply, join_control(state)}

  def handle_info({:rpc_result, task_ref, generation, result}, state) do
    case pop_rpc_task(state, task_ref) do
      {:ok, task, state} ->
        Process.demonitor(task.monitor_ref, [:flush])

        if generation == task.generation and current_rpc_generation?(task, state) do
          send_rpc_result(result, state)
        end

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp join_control(state) do
    case state.join_fun.(state.socket, state.topic) do
      {:ok, _response, channel} ->
        state
        |> put_channel(channel)
        |> send_initial_capabilities()
        |> send_current_heartbeat()
        |> schedule_heartbeat()

      {:error, {:already_joined, channel}} ->
        state
        |> put_channel(channel)
        |> send_initial_capabilities()
        |> send_current_heartbeat()
        |> schedule_heartbeat()

      {:error, reason} ->
        log_transport_failure("Commander control channel unavailable", state, reason)
        schedule_reconnect(state)
    end
  end

  defp handle_payload(payload, state) do
    case Envelope.decode(payload) do
      {:ok, %RPCRequest{} = request} ->
        emit_rpc_telemetry(request, payload, state)
        {:noreply, handle_rpc_request(request, state)}

      {:ok, %EventAck{} = ack} ->
        notify_event_ack(ack, state)
        {:noreply, state}

      {:ok, _unexpected_envelope} ->
        GSMLG.Telemetry.warn("Unexpected Commander control message",
          metadata: %{
            commander_id: state.commander_name,
            message_code: message_code(payload),
            payload_size: encoded_size(payload)
          }
        )

        {:noreply, state}

      {:error, error} ->
        GSMLG.Telemetry.warn("Invalid Commander control message",
          metadata: %{
            commander_id: state.commander_name,
            message_code: message_code(payload),
            payload_size: encoded_size(payload),
            error_code: error.code
          }
        )

        {:noreply, state}
    end
  end

  defp send_rpc_result({:ok, envelope}, state), do: send_envelope(envelope, state)
  defp send_rpc_result({:error, envelope}, state), do: send_envelope(envelope, state)

  defp handle_rpc_request(request, state) do
    case active_request_result(request, state) do
      :new -> admit_unique_request(request, state)
      existing -> send_admission_result(request, existing, state)
    end
  end

  defp admit_unique_request(request, state)
       when map_size(state.rpc_tasks) < state.max_in_flight_rpcs do
    start_rpc_task(request, state)
  end

  defp admit_unique_request(request, state) do
    result =
      case lookup_request(request, state) do
        :new -> {:overloaded, state.max_in_flight_rpcs}
        existing -> existing
      end

    send_admission_result(request, result, state)
  end

  defp start_rpc_task(request, state) do
    connection = self()
    task_ref = make_ref()
    generation = state.channel_generation
    route_fun = state.rpc_route_fun
    route_opts = router_opts(state)

    task = fn ->
      receive do
        :execute ->
          result = route_fun.(request, route_opts)
          send(connection, {:rpc_result, task_ref, generation, result})
      end
    end

    case start_task(state.rpc_task_supervisor, task) do
      {:ok, task_pid} ->
        monitor_ref = Process.monitor(task_pid)

        rpc_task = %{
          pid: task_pid,
          monitor_ref: monitor_ref,
          generation: generation,
          request: request,
          fingerprint: RequestDedup.fingerprint(request)
        }

        send(task_pid, :execute)
        %{state | rpc_tasks: Map.put(state.rpc_tasks, task_ref, rpc_task)}

      {:error, _reason} ->
        send_admission_result(request, {:overloaded, state.max_in_flight_rpcs}, state)
    end
  end

  defp start_task(nil, task), do: Task.start(task)
  defp start_task(supervisor, task), do: Task.Supervisor.start_child(supervisor, task)

  defp active_request_result(request, state) do
    fingerprint = RequestDedup.fingerprint(request)

    Enum.find_value(state.rpc_tasks, :new, fn {_task_ref, active} ->
      cond do
        request.request_id == active.request.request_id and fingerprint != active.fingerprint ->
          {:error, :request_payload_collision}

        request.request_id == active.request.request_id ->
          {:in_progress, active.request.request_id}

        request.idempotency_key == active.request.idempotency_key and
            fingerprint != active.fingerprint ->
          {:error, :idempotency_payload_collision}

        request.idempotency_key == active.request.idempotency_key ->
          {:in_progress, active.request.request_id}

        true ->
          false
      end
    end)
  end

  defp lookup_request(request, state) do
    RequestDedup.lookup(state.request_dedup, request)
  rescue
    _exception -> :new
  catch
    :exit, _reason -> :new
  end

  defp send_admission_result(request, result, state) do
    request
    |> RPCRouter.admission_result(result)
    |> send_rpc_result(state)

    state
  end

  defp pop_rpc_task(state, task_ref) do
    case Map.pop(state.rpc_tasks, task_ref) do
      {nil, _tasks} -> :error
      {task, tasks} -> {:ok, task, %{state | rpc_tasks: tasks}}
    end
  end

  defp pop_rpc_task_by_monitor(state, monitor_ref, task_pid) do
    Enum.find_value(state.rpc_tasks, :error, fn {task_ref, task} ->
      if task.monitor_ref == monitor_ref and task.pid == task_pid do
        {:ok, task, %{state | rpc_tasks: Map.delete(state.rpc_tasks, task_ref)}}
      end
    end)
  end

  defp current_rpc_generation?(task, state) do
    task.generation == state.channel_generation and not is_nil(state.channel)
  end

  defp send_initial_capabilities(%{initial_capabilities_sent: true} = state), do: state

  defp send_initial_capabilities(state) do
    capabilities =
      state.capability_registry
      |> CapabilityRegistry.list()
      |> Enum.map(&elem(&1, 0))

    negotiation = %VersionNegotiation{
      protocol_version: Envelope.protocol_version(),
      capabilities: capabilities
    }

    case send_envelope(negotiation, state) do
      :ok -> %{state | initial_capabilities_sent: true}
      {:error, _reason} -> state
    end
  end

  defp send_capability_update(_descriptors, %{initial_capabilities_sent: false} = state),
    do: state

  defp send_capability_update(descriptors, state) do
    update = %CapabilitiesUpdate{
      protocol_version: Envelope.protocol_version(),
      capabilities: descriptors
    }

    send_envelope(update, state)
    state
  end

  defp send_envelope(envelope, state) do
    with {:ok, wire} <- Envelope.encode(envelope) do
      send_wire(wire, state)
    end
  end

  defp send_wire(_wire, %{channel: nil}), do: {:error, :not_joined}
  defp send_wire(wire, state), do: state.push_fun.(state.channel, "message", wire)

  defp send_current_heartbeat(%{initial_capabilities_sent: false} = state), do: state

  defp send_current_heartbeat(state) do
    heartbeat = %{
      "type" => "heartbeat",
      "protocol_version" => Envelope.protocol_version(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "capability_count" => length(CapabilityRegistry.list(state.capability_registry)),
      "tls" => tls_summary(state.tls_summary_fun)
    }

    _result = send_wire(heartbeat, state)
    state
  end

  defp notify_event_ack(ack, state) do
    with {:ok, capability_id} <-
           RequestDedup.execution_capability(state.request_dedup, ack.remote_execution_id),
         {:ok, {_descriptor, handler}} <-
           CapabilityRegistry.fetch(state.capability_registry, capability_id) do
      notify_handler(handler, ack)
    else
      _unknown_or_removed -> :ok
    end
  end

  defp notify_handler(handler, ack) when is_function(handler, 1), do: handler.({:event_ack, ack})

  defp notify_handler(handler, ack) when is_atom(handler) do
    if function_exported?(handler, :handle_event_ack, 1), do: handler.handle_event_ack(ack)
  end

  defp notify_handler(handler, ack) when is_pid(handler), do: send(handler, {:event_ack, ack})
  defp notify_handler(_handler, _ack), do: :ok

  defp emit_rpc_telemetry(request, payload, state) do
    payload_size = payload |> JSON.encode!() |> byte_size()

    GSMLG.Telemetry.emit(
      [:gsmlg, :commander, :rpc, :request],
      %{payload_size: payload_size},
      %{
        commander_id: state.commander_name,
        request_id: request.request_id,
        capability: request.capability,
        operation: request.operation
      }
    )
  end

  defp message_code(%{"type" => "version.negotiation"}), do: :version_negotiation
  defp message_code(%{"type" => "capabilities.update"}), do: :capabilities_update
  defp message_code(%{"type" => "capability.descriptor"}), do: :capability_descriptor
  defp message_code(%{"type" => "rpc.request"}), do: :rpc_request
  defp message_code(%{"type" => "rpc.accepted"}), do: :rpc_accepted
  defp message_code(%{"type" => "rpc.response"}), do: :rpc_response
  defp message_code(%{"type" => "rpc.error"}), do: :rpc_error
  defp message_code(%{"type" => "job.event"}), do: :job_event
  defp message_code(%{"type" => "event.ack"}), do: :event_ack
  defp message_code(_payload), do: :unknown

  defp encoded_size(payload) do
    payload |> JSON.encode!() |> byte_size()
  rescue
    _exception -> 0
  end

  defp tls_summary(summary_fun) do
    case summary_fun.() |> TLSSummary.validate() do
      {:ok, summary} -> summary
      {:error, :invalid_tls_summary} -> %{"status" => "invalid"}
    end
  rescue
    _exception -> %{"status" => "invalid"}
  catch
    _kind, _reason -> %{"status" => "invalid"}
  end

  defp router_opts(state) do
    [registry: state.capability_registry, request_dedup: state.request_dedup]
  end

  defp log_transport_failure(message, state, reason) do
    GSMLG.Telemetry.info(message,
      metadata: %{commander_id: state.commander_name, reason: safe_reason(reason)}
    )
  end

  defp safe_reason(reason) when reason in [:socket_not_connected, :socket_not_started], do: reason
  defp safe_reason(_reason), do: :transport_error

  defp put_channel(state, channel) do
    generation = state.channel_generation + 1
    state = clear_channel(state)

    # WORKAROUND(upstream): gsmlg-dev/phoenix_socket_client#106
    # The dependency does not currently rejoin channels it terminates on reconnect.
    ref = if is_pid(channel), do: Process.monitor(channel)

    %{
      state
      | channel: channel,
        channel_ref: ref,
        initial_capabilities_sent: false,
        channel_generation: generation
    }
  end

  defp clear_channel(%{channel_ref: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    %{state | channel: nil, channel_ref: nil, initial_capabilities_sent: false}
  end

  defp clear_channel(state),
    do: %{state | channel: nil, channel_ref: nil, initial_capabilities_sent: false}

  defp schedule_reconnect(state) do
    Process.send_after(self(), :reconnect, state.reconnect_after)
    state
  end

  defp schedule_heartbeat(state) do
    state = cancel_heartbeat(state)
    timer = Process.send_after(self(), :heartbeat, state.heartbeat_interval)
    %{state | heartbeat_timer: timer}
  end

  defp cancel_heartbeat(%{heartbeat_timer: nil} = state), do: state

  defp cancel_heartbeat(state) do
    Process.cancel_timer(state.heartbeat_timer)
    %{state | heartbeat_timer: nil}
  end
end

defmodule GSMLG.Commander.ConnectionSupervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :supervisor_name, __MODULE__))
  end

  def restart(supervisor \\ __MODULE__) do
    with :ok <- terminate_if_running(supervisor, :control_channel),
         :ok <- terminate_if_running(supervisor, :socket),
         {:ok, _socket} <- restart_child(supervisor, :socket),
         {:ok, _connection} <- restart_child(supervisor, :control_channel) do
      :ok
    end
  end

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    socket_name = Keyword.get(opts, :socket_name, GSMLG.Commander.Socket)
    connection_name = Keyword.get(opts, :connection_name, GSMLG.Commander.Connection)

    rpc_task_supervisor =
      Keyword.get(opts, :rpc_task_supervisor, GSMLG.Commander.RPCTaskSupervisor)

    max_in_flight_rpcs =
      Keyword.get(opts, :max_in_flight_rpcs, GSMLG.Commander.max_in_flight_rpcs(config))

    socket =
      {Phoenix.SocketClient, GSMLG.Commander.socket_opts(config) ++ [name: socket_name]}
      |> Supervisor.child_spec(id: :socket)

    connection =
      {GSMLG.Commander.Connection,
       socket: socket_name,
       commander_name: Keyword.fetch!(config, :name),
       tls_summary_fun: fn ->
         GSMLG.Commander.TLS.connection_summary(
           Keyword.fetch!(config, :platform_url),
           Keyword.get(config, :tls, [])
         )
       end,
       rpc_task_supervisor: rpc_task_supervisor,
       max_in_flight_rpcs: max_in_flight_rpcs,
       name: connection_name}
      |> Supervisor.child_spec(id: :control_channel)

    Supervisor.init([socket, connection], strategy: :rest_for_one)
  end

  defp terminate_if_running(supervisor, child_id) do
    case Supervisor.terminate_child(supervisor, child_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp restart_child(supervisor, child_id) do
    case Supervisor.restart_child(supervisor, child_id) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      {:error, :running} -> {:ok, :running}
      {:error, reason} -> {:error, reason}
    end
  end
end
