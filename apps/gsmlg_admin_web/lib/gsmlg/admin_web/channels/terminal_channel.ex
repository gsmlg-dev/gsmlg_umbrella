defmodule GSMLG.AdminWeb.TerminalChannel do
  @moduledoc """
  Server-side Phoenix channel for PTY terminal sessions.

  Accepts connections from PTY agents and handles bidirectional
  communication for terminal sessions, including command dispatch
  and output streaming to admin UI.
  """

  use Phoenix.Channel
  require Logger

  @impl true
  def join("terminal:" <> commander_name, _payload, socket) do
    commander_name = socket.assigns[:commander_name] || commander_name

    GSMLG.Telemetry.info("Terminal channel joined",
      metadata: %{
      commander: commander_name,
      socket_id: socket.id
    })

    # Register agent in registry
    case GSMLG.CommandPlatform.AgentRegistry.register_agent(commander_name, self()) do
      :ok ->
        # Subscribe to admin UI broadcasts for this commander
        Phoenix.PubSub.subscribe(GSMLG.PubSub, "terminal:#{commander_name}:admin")

        socket = assign(socket, :commander_name, commander_name)
        {:ok, %{status: "connected", commander: commander_name}, socket}

      {:error, reason} ->
        GSMLG.Telemetry.error("Failed to register agent",
      metadata: %{
          commander: commander_name,
          reason: inspect(reason)
        })

        {:error, %{reason: "registration_failed"}}
    end
  end

  @impl true
  def handle_in("message", payload, socket) do
    commander_name = socket.assigns.commander_name

    GSMLG.Telemetry.debug("Received message from agent",
      metadata: %{
      commander: commander_name,
      type: payload["type"]
    })

    case payload["type"] do
      "register" ->
        handle_register(payload, socket)

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

      "heartbeat" ->
        handle_heartbeat(payload, socket)

      "sessions_list" ->
        handle_sessions_list(payload, socket)

      _ ->
        GSMLG.Telemetry.warn("Unknown message type from agent",
      metadata: %{
          commander: commander_name,
          type: payload["type"]
        })

        {:noreply, socket}
    end
  end

  @impl true
  def handle_in("command", payload, socket) do
    # Legacy command handling from admin UI
    commander_name = socket.assigns.commander_name

    GSMLG.Telemetry.info("Dispatching command to agent",
      metadata: %{
      commander: commander_name,
      command_type: payload["type"]
    })

    {:noreply, socket}
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

    push(socket, "message", message)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:close_pty, session_id, force}, socket) do
    message = %{
      type: "close_pty",
      session_id: session_id,
      force: force || false
    }

    push(socket, "message", message)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:attach_pty, session_id}, socket) do
    message = %{
      type: "attach_pty",
      session_id: session_id
    }

    push(socket, "message", message)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:detach_pty, session_id}, socket) do
    message = %{
      type: "detach_pty",
      session_id: session_id
    }

    push(socket, "message", message)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:send_input, session_id, data}, socket) do
    message = %{
      type: "send_input",
      session_id: session_id,
      data: data
    }

    push(socket, "message", message)
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

    push(socket, "message", message)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:list_sessions}, socket) do
    message = %{
      type: "list_sessions"
    }

    push(socket, "message", message)
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
      GSMLG.Telemetry.info("Terminal channel terminated",
      metadata: %{
        commander: commander_name
      })

      GSMLG.CommandPlatform.AgentRegistry.unregister_agent(commander_name)

      # Broadcast agent disconnection
      Phoenix.PubSub.broadcast(
        GSMLG.PubSub,
        "commander_updates",
        {:agent_disconnected, commander_name}
      )
    end

    :ok
  end

  # Private Message Handlers

  defp handle_register(payload, socket) do
    commander_name = socket.assigns.commander_name

    agent_info = %{
      agent_id: payload["agent_id"] || commander_name,
      hostname: payload["hostname"],
      capabilities: payload["capabilities"] || [],
      version: payload["version"],
      active_sessions: payload["active_sessions"] || 0,
      sessions: payload["sessions"] || []
    }

    GSMLG.Telemetry.info("Agent registered",
      metadata: %{
      commander: commander_name,
      info: agent_info
    })

    # Update agent info in registry
    GSMLG.CommandPlatform.AgentRegistry.update_agent_info(commander_name, agent_info)

    # Track sessions
    Enum.each(agent_info.sessions, fn session_id ->
      GSMLG.CommandPlatform.SessionTracker.register_session(
        commander_name,
        session_id,
        %{reconnected: true}
      )
    end)

    # Broadcast to admin UI
    Phoenix.PubSub.broadcast(
      GSMLG.PubSub,
      "commander_updates",
      {:agent_registered, commander_name, agent_info}
    )

    {:reply, :ok, socket}
  end

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
      metadata: %{
      commander: commander_name,
      session_id: session_id
    })

    # Register session in tracker
    GSMLG.CommandPlatform.SessionTracker.register_session(
      commander_name,
      session_id,
      session_info
    )

    # Broadcast to admin UI
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
      metadata: %{
      commander: commander_name,
      session_id: session_id,
      exit_code: payload["exit_code"]
    })

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
      metadata: %{
      commander: commander_name,
      error_code: payload["error_code"],
      message: payload["message"],
      session_id: payload["session_id"]
    })

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

  defp handle_heartbeat(payload, socket) do
    commander_name = socket.assigns.commander_name

    GSMLG.CommandPlatform.AgentRegistry.heartbeat(commander_name, %{
      active_sessions: payload["active_sessions"],
      timestamp: payload["timestamp"]
    })

    {:noreply, socket}
  end

  defp handle_sessions_list(payload, socket) do
    commander_name = socket.assigns.commander_name
    sessions = payload["sessions"] || []

    GSMLG.Telemetry.debug("Received sessions list from agent",
      metadata: %{
      commander: commander_name,
      count: length(sessions)
    })

    # Update session tracker
    Enum.each(sessions, fn session ->
      GSMLG.CommandPlatform.SessionTracker.sync_session(commander_name, session)
    end)

    {:noreply, socket}
  end
end
