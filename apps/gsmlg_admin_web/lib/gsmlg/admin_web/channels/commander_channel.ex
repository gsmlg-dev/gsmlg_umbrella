defmodule GSMLG.AdminWeb.CommanderChannel do
  @moduledoc """
  Commander Channel

  """
  use Phoenix.Channel

  alias GSMLG.Commander.Protocol.{
    CapabilitiesUpdate,
    Envelope,
    JobEvent,
    RPCAccepted,
    RPCError,
    RPCResponse,
    TLSSummary,
    VersionNegotiation
  }

  alias Phoenix.Socket.Broadcast

  @broadcast_event_codes %{"message" => :message, "command" => :command}

  @impl true
  def join("commander:" <> name, _msg, socket) do
    if socket.assigns[:commander_name] == name do
      GSMLG.Telemetry.info("Commander control channel joined",
        metadata: %{commander_id: name, credential_id: socket.assigns[:credential_id]}
      )

      {:ok, %{status: "negotiation_required", commander: name},
       socket |> assign(:negotiated, false) |> assign(:generation, nil)}
    else
      {:error, %{reason: "identity_mismatch"}}
    end
  end

  @impl true
  def terminate(reason, socket) do
    commander_id = socket.assigns[:commander_name]

    if commander_id && socket.assigns[:negotiated] do
      GSMLG.CommandPlatform.AgentRegistry.unregister_agent(
        commander_id,
        self(),
        socket.assigns[:generation]
      )
    end

    GSMLG.Telemetry.debug("Commander control channel terminated",
      metadata: %{commander_id: commander_id, reason: safe_reason(reason)}
    )

    :ok
  end

  @impl true
  def handle_info(%Broadcast{topic: _, event: event, payload: payload}, socket) do
    GSMLG.Telemetry.debug("Broadcast received in commander channel",
      metadata: %{
        channel: "commander",
        event_code: broadcast_event_code(event),
        event_size: binary_size(event),
        payload_size: encoded_size(payload),
        socket_id: socket.id
      }
    )

    if current?(socket), do: push(socket, event, payload)
    {:noreply, socket}
  end

  def handle_info({:commander_rpc, wire}, socket) do
    if current?(socket), do: push(socket, "message", wire)
    {:noreply, socket}
  end

  def handle_info({:commander_event_ack, wire}, socket) do
    if current?(socket), do: push(socket, "message", wire)
    {:noreply, socket}
  end

  @impl true
  def handle_in("ping", %{"message" => "ping", "time" => time}, socket) do
    GSMLG.Telemetry.debug("Ping received in commander channel",
      metadata: %{
        channel: "commander",
        message_type: "ping",
        client_time_size: binary_size(time),
        socket_id: socket.id
      }
    )

    {:reply, {:ok, %{"message" => "pong", "time" => System.system_time(:second)}}, socket}
  end

  def handle_in("message", %{"type" => "heartbeat"} = heartbeat, socket) do
    with true <- socket.assigns[:negotiated] || {:error, :negotiation_required},
         true <- current?(socket) || {:error, :stale_generation},
         true <-
           heartbeat["protocol_version"] == Envelope.protocol_version() ||
             {:error, :unsupported_protocol_version},
         {:ok, heartbeat_info} <- heartbeat_info(heartbeat),
         :ok <-
           GSMLG.CommandPlatform.AgentRegistry.fenced_heartbeat(
             socket.assigns.commander_name,
             self(),
             socket.assigns.generation,
             connection_id(socket),
             heartbeat_info
           ) do
      {:reply, :ok, socket}
    else
      {:error, reason} -> {:reply, {:error, %{reason: Atom.to_string(reason)}}, socket}
    end
  end

  def handle_in("message", payload, socket) do
    if stale_message?(payload, socket) do
      {:reply, {:error, %{reason: "stale_generation"}}, socket}
    else
      decode_message(payload, socket)
    end
  end

  def handle_in(any, payload, socket) do
    GSMLG.Telemetry.warn("Unmatched message in commander channel",
      metadata: %{
        channel: "commander",
        event_code: :unknown,
        event_size: binary_size(any),
        payload_size: encoded_size(payload),
        socket_id: socket.id
      }
    )

    {:noreply, socket}
  end

  defp decode_message(payload, socket) do
    case Envelope.decode(payload) do
      {:ok, %VersionNegotiation{} = negotiation} ->
        negotiate(negotiation, socket)

      {:ok, %CapabilitiesUpdate{} = update} ->
        update_capabilities(update, socket)

      {:ok, message}
      when is_struct(message, RPCAccepted) or is_struct(message, RPCResponse) or
             is_struct(message, RPCError) or is_struct(message, JobEvent) ->
        if current?(socket) do
          case GSMLG.CommandPlatform.RPCDispatcher.route_incoming(
                 socket.assigns.commander_name,
                 message
               ) do
            :ok -> {:reply, :ok, socket}
            {:error, reason} -> {:reply, {:error, %{reason: Atom.to_string(reason)}}, socket}
          end
        else
          {:reply, {:error, %{reason: stale_reason(socket)}}, socket}
        end

      {:ok, _unexpected} ->
        {:reply, {:error, %{reason: "unexpected_message_type"}}, socket}

      {:error, error} ->
        {:reply, {:error, %{reason: error.code}}, socket}
    end
  end

  defp encoded_size(payload) do
    payload |> JSON.encode!() |> byte_size()
  rescue
    _exception -> 0
  end

  defp binary_size(value) when is_binary(value), do: byte_size(value)
  defp binary_size(_value), do: 0

  defp heartbeat_info(heartbeat) do
    info = %{
      protocol_version: heartbeat["protocol_version"],
      capability_count: heartbeat["capability_count"],
      remote_timestamp: heartbeat["timestamp"]
    }

    case Map.fetch(heartbeat, "tls") do
      {:ok, summary} ->
        with {:ok, summary} <- TLSSummary.validate(summary),
             do: {:ok, Map.put(info, :tls, summary)}

      :error ->
        {:ok, info}
    end
  end

  defp broadcast_event_code(event), do: Map.get(@broadcast_event_codes, event, :unknown)

  defp safe_reason(reason) when reason in [:normal, :shutdown], do: reason
  defp safe_reason(_reason), do: :channel_closed

  defp negotiate(_negotiation, %{assigns: %{negotiated: true}} = socket) do
    {:reply, {:error, %{reason: "already_negotiated"}}, socket}
  end

  defp negotiate(negotiation, socket) do
    info = %{
      protocol_version: negotiation.protocol_version,
      capability_descriptors: negotiation.capabilities,
      capabilities: legacy_capabilities(negotiation.capabilities)
    }

    {:ok, generation} =
      GSMLG.CommandPlatform.AgentRegistry.activate_agent(
        socket.assigns.commander_name,
        self(),
        info,
        connection_id(socket)
      )

    :ok = GSMLG.CommandPlatform.RPCDispatcher.replay_pending(socket.assigns.commander_name)

    socket = socket |> assign(:negotiated, true) |> assign(:generation, generation)
    {:reply, {:ok, %{capabilities: length(negotiation.capabilities)}}, socket}
  end

  defp legacy_capabilities(descriptors) do
    if Enum.any?(descriptors, &(&1.id == "pty.shell")), do: [:shell], else: []
  end

  defp update_capabilities(update, socket) do
    if current?(socket) do
      info = %{
        capability_descriptors: update.capabilities,
        capabilities: legacy_capabilities(update.capabilities)
      }

      case GSMLG.CommandPlatform.AgentRegistry.fenced_capabilities_update(
             socket.assigns.commander_name,
             self(),
             socket.assigns.generation,
             connection_id(socket),
             info
           ) do
        :ok -> {:reply, {:ok, %{capabilities: length(update.capabilities)}}, socket}
        {:error, reason} -> {:reply, {:error, %{reason: Atom.to_string(reason)}}, socket}
      end
    else
      {:reply, {:error, %{reason: stale_reason(socket)}}, socket}
    end
  end

  defp current?(socket) do
    socket.assigns[:negotiated] &&
      GSMLG.CommandPlatform.AgentRegistry.current?(
        socket.assigns.commander_name,
        self(),
        socket.assigns.generation,
        connection_id(socket)
      )
  end

  defp stale_message?(%{"type" => "version.negotiation"}, _socket), do: false

  defp stale_message?(_payload, socket) do
    socket.assigns[:negotiated] && not current?(socket)
  end

  defp connection_id(socket), do: socket.assigns[:connection_id] || socket.id

  defp stale_reason(socket) do
    if socket.assigns[:negotiated], do: "stale_generation", else: "negotiation_required"
  end
end
