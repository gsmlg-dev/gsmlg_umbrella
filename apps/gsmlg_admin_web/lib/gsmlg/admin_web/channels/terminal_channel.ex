defmodule GSMLG.AdminWeb.TerminalChannel do
  @moduledoc """
  Server-side Phoenix channel for PTY terminal sessions.

  Accepts connections from PTY agents and handles bidirectional
  communication for terminal sessions, including command dispatch
  and output streaming to admin UI.
  """

  use Phoenix.Channel
  require Logger

  @agent_message_types ~w(pty_output pty_created pty_closed pty_resized error sessions_list)
  @agent_error_codes ~w(pty_spawn_failed create_failed)
  @legacy_command_codes %{
    "create_pty" => :create_pty,
    "close_pty" => :close_pty,
    "attach_pty" => :attach_pty,
    "detach_pty" => :detach_pty,
    "send_input" => :send_input,
    "resize_pty" => :resize_pty,
    "list_sessions" => :list_sessions,
    "configure" => :configure
  }

  @impl true
  def join("terminal:" <> commander_name, _payload, socket) do
    cond do
      socket.assigns[:commander_name] != commander_name ->
        {:error, %{reason: "identity_mismatch"}}

      not GSMLG.CommandPlatform.AgentRegistry.agent_connected?(commander_name) ->
        {:error, %{reason: "control_channel_required"}}

      true ->
        case GSMLG.CommandPlatform.AgentRegistry.attach_terminal(
               commander_name,
               self(),
               connection_id(socket)
             ) do
          {:ok, generation} ->
            Phoenix.PubSub.subscribe(GSMLG.PubSub, "terminal:#{commander_name}:admin")

            socket =
              socket
              |> assign(:commander_name, commander_name)
              |> assign(:terminal_generation, generation)

            {:ok, %{status: "connected", commander: commander_name}, socket}

          {:error, :stale_generation} ->
            {:error, %{reason: "control_connection_mismatch"}}
        end
    end
  end

  @impl true
  def handle_in("message", payload, socket) do
    if current?(socket) do
      handle_agent_message(payload, socket)
    else
      {:reply, {:error, %{reason: "stale_generation"}}, socket}
    end
  end

  @impl true
  def handle_in("command", payload, socket) do
    if current?(socket) do
      # Legacy command handling from admin UI
      commander_name = socket.assigns.commander_name

      GSMLG.Telemetry.info("Dispatching command to agent",
        metadata: %{
          commander: commander_name,
          command_code: legacy_command_code(payload["type"]),
          payload_size: encoded_size(payload)
        }
      )

      {:noreply, socket}
    else
      {:reply, {:error, %{reason: "stale_generation"}}, socket}
    end
  end

  defp handle_agent_message(payload, socket) do
    commander_name = socket.assigns.commander_name

    GSMLG.Telemetry.debug("Received message from agent",
      metadata: %{
        commander: commander_name,
        message_code: agent_message_code(payload["type"]),
        payload_size: encoded_size(payload)
      }
    )

    case payload["type"] do
      "pty_output" ->
        handle_pty_output(payload, socket)

      "pty_created" ->
        handle_pty_created(payload, socket)

      "pty_closed" ->
        handle_pty_closed(payload, socket)

      "pty_resized" ->
        handle_pty_resized(payload, socket)

      "error" ->
        handle_error(payload, socket)

      "sessions_list" ->
        handle_sessions_list(payload, socket)

      _ ->
        GSMLG.Telemetry.warn("Unknown message type from agent",
          metadata: %{
            commander: commander_name,
            message_code: :unknown,
            payload_size: encoded_size(payload)
          }
        )

        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:create_pty, params}, socket) do
    # Command from admin UI to create PTY
    message = %{
      type: "create_pty",
      session_id: params.session_id,
      command: params.command,
      dimensions: params.dimensions,
      env_vars: params.env_vars || %{},
      working_dir: params.working_dir
    }

    push_if_current(socket, "message", message)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:close_pty, session_id, force}, socket) do
    message = %{
      type: "close_pty",
      session_id: session_id,
      force: force || false
    }

    push_if_current(socket, "message", message)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:attach_pty, session_id}, socket) do
    message = %{
      type: "attach_pty",
      session_id: session_id
    }

    push_if_current(socket, "message", message)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:detach_pty, session_id}, socket) do
    message = %{
      type: "detach_pty",
      session_id: session_id
    }

    push_if_current(socket, "message", message)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:send_input, session_id, data}, socket) do
    message = %{
      type: "send_input",
      session_id: session_id,
      data: data
    }

    push_if_current(socket, "message", message)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:resize_pty, session_id, rows, cols}, socket) do
    message = %{
      type: "resize_pty",
      session_id: session_id,
      rows: rows,
      cols: cols
    }

    push_if_current(socket, "message", message)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:list_sessions}, socket) do
    message = %{
      type: "list_sessions"
    }

    push_if_current(socket, "message", message)
    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    commander_name = socket.assigns[:commander_name]

    if commander_name do
      GSMLG.CommandPlatform.AgentRegistry.detach_terminal(
        commander_name,
        self(),
        connection_id(socket),
        socket.assigns[:terminal_generation]
      )

      GSMLG.Telemetry.info("Terminal channel terminated",
        metadata: %{
          commander: commander_name
        }
      )
    end

    :ok
  end

  # Private Message Handlers

  defp handle_pty_output(payload, socket) do
    session_id = payload["session_id"]
    data = payload["data"]
    commander_name = socket.assigns.commander_name

    # Broadcast output to admin UI subscribers for this session
    Phoenix.PubSub.broadcast(
      GSMLG.PubSub,
      "pty_session:#{session_id}",
      {:pty_output, session_id, data}
    )

    # Update session last activity
    GSMLG.CommandPlatform.SessionTracker.update_activity(commander_name, session_id)

    {:noreply, socket}
  end

  defp handle_pty_created(payload, socket) do
    session_id = payload["session_id"]
    commander_name = socket.assigns.commander_name

    session_info = %{
      session_id: session_id,
      agent_id: commander_name,
      command: payload["command"],
      dimensions: payload["dimensions"],
      os_pid: payload["os_pid"],
      state: :running,
      created_at: System.system_time(:millisecond)
    }

    GSMLG.Telemetry.info("PTY session created",
      metadata: Map.put(session_metadata(session_id), :commander, commander_name)
    )

    # Register session in tracker
    GSMLG.CommandPlatform.SessionTracker.register_session_async(
      commander_name,
      session_id,
      session_info
    )

    # Broadcast to admin UI
    Phoenix.PubSub.broadcast(
      GSMLG.PubSub,
      "pty_session:#{session_id}",
      {:pty_created, session_id, session_info}
    )

    Phoenix.PubSub.broadcast(
      GSMLG.PubSub,
      "pty_sessions",
      {:session_created, session_info}
    )

    {:noreply, socket}
  end

  defp handle_pty_closed(payload, socket) do
    session_id = payload["session_id"]
    commander_name = socket.assigns.commander_name

    GSMLG.Telemetry.info("PTY session closed",
      metadata:
        session_metadata(session_id)
        |> Map.put(:commander, commander_name)
        |> Map.put(:exit_code, normalized_exit_code(payload["exit_code"]))
    )

    # Update session state
    GSMLG.CommandPlatform.SessionTracker.close_session(
      commander_name,
      session_id,
      payload["exit_code"]
    )

    # Broadcast to admin UI
    Phoenix.PubSub.broadcast(
      GSMLG.PubSub,
      "pty_session:#{session_id}",
      {:pty_closed, session_id, payload["exit_code"], payload["reason"]}
    )

    Phoenix.PubSub.broadcast(
      GSMLG.PubSub,
      "pty_sessions",
      {:session_closed, session_id}
    )

    {:noreply, socket}
  end

  defp handle_pty_resized(payload, socket) do
    session_id = payload["session_id"]

    # Broadcast to admin UI
    Phoenix.PubSub.broadcast(
      GSMLG.PubSub,
      "pty_session:#{session_id}",
      {:pty_resized, session_id, payload["rows"], payload["cols"]}
    )

    {:noreply, socket}
  end

  defp handle_error(payload, socket) do
    commander_name = socket.assigns.commander_name

    GSMLG.Telemetry.error("Agent reported error",
      metadata:
        session_metadata(payload["session_id"])
        |> Map.put(:commander, commander_name)
        |> Map.put(:error_code, normalized_agent_error_code(payload["error_code"]))
        |> Map.put(:message_size, message_size(payload["message"]))
    )

    # Broadcast to admin UI
    if payload["session_id"] do
      Phoenix.PubSub.broadcast(
        GSMLG.PubSub,
        "pty_session:#{payload["session_id"]}",
        {:pty_error, payload["session_id"], payload["error_code"], payload["message"]}
      )
    end

    {:noreply, socket}
  end

  defp agent_message_code(type) when type in @agent_message_types, do: type
  defp agent_message_code(_type), do: :unknown

  defp normalized_agent_error_code(code) when code in @agent_error_codes, do: code
  defp normalized_agent_error_code(_code), do: "unknown_agent_error"

  defp legacy_command_code(type), do: Map.get(@legacy_command_codes, type, :unknown)

  defp normalized_exit_code(code) when is_integer(code) and code >= -255 and code <= 255, do: code
  defp normalized_exit_code(_code), do: :unknown

  defp message_size(message) when is_binary(message), do: byte_size(message)
  defp message_size(_message), do: 0

  defp encoded_size(payload) do
    payload |> JSON.encode!() |> byte_size()
  rescue
    _exception -> 0
  end

  defp session_metadata(session_id) when is_binary(session_id) do
    %{
      session_id_hash: :crypto.hash(:sha256, session_id) |> Base.encode16(case: :lower),
      session_id_size: byte_size(session_id)
    }
  end

  defp session_metadata(_session_id), do: %{session_id_hash: nil, session_id_size: 0}

  defp current?(socket) do
    GSMLG.CommandPlatform.AgentRegistry.current_terminal?(
      socket.assigns.commander_name,
      self(),
      connection_id(socket),
      socket.assigns[:terminal_generation]
    )
  end

  defp push_if_current(socket, event, message) do
    if current?(socket), do: push(socket, event, message)
  end

  defp connection_id(socket), do: socket.assigns[:connection_id] || socket.id

  defp handle_sessions_list(payload, socket) do
    commander_name = socket.assigns.commander_name
    sessions = payload["sessions"] || []

    GSMLG.Telemetry.debug("Received sessions list from agent",
      metadata: %{
        commander: commander_name,
        count: length(sessions)
      }
    )

    # Update session tracker
    Enum.each(sessions, fn session ->
      GSMLG.CommandPlatform.SessionTracker.sync_session(commander_name, session)
    end)

    {:noreply, socket}
  end
end
