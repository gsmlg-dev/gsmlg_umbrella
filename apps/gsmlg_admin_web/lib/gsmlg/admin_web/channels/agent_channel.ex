defmodule GSMLG.AdminWeb.AgentChannel do
  @moduledoc """
  Phoenix Channel for commander agent connections.

  Handles WebSocket connections from remote commander agents,
  authentication handshake, PTY output forwarding, and heartbeat monitoring.

  ## Channel Topic

  `agent:connect` - Single topic for all agent connections

  ## Authentication Flow

  1. Agent joins with token in params
  2. Server validates token via TokenManager
  3. On success: Session created, agent metadata stored
  4. On failure: Connection rejected with error reason
  """

  # Suppress undefined module warnings for Commander modules (loaded at runtime)
  @compile {:no_warn_undefined, [GSMLG.Commander.TokenManager, GSMLG.Commander.SessionManager]}

  use Phoenix.Channel
  require Logger

  alias GSMLG.Commander.{TokenManager, SessionManager}

  @heartbeat_timeout :timer.seconds(90)

  @impl true
  def join("agent:connect", %{"token" => token} = params, socket) do
    case TokenManager.validate_token(token) do
      {:ok, validated_token} ->
        agent_name = params["name"] || generate_agent_name()
        agent_metadata = extract_agent_metadata(params)

        # Create session for this agent
        session_opts = [
          command: params["shell"] || "/bin/bash",
          terminal_pid: self(),
          env_vars: %{"TERM" => "xterm-256color"},
          dimensions: %{rows: params["rows"] || 24, cols: params["cols"] || 80}
        ]

        case SessionManager.create_session(session_opts) do
          {:ok, session_id} ->
            socket =
              socket
              |> assign(:agent_name, agent_name)
              |> assign(:session_id, session_id)
              |> assign(:token_id, validated_token.id)
              |> assign(:capabilities, validated_token.capabilities)
              |> assign(:auto_tags, validated_token.auto_tags)
              |> assign(:agent_metadata, agent_metadata)
              |> assign(:connected_at, DateTime.utc_now())
              |> assign(:last_heartbeat, System.system_time(:millisecond))

            # Start heartbeat monitoring
            schedule_heartbeat_check()

            # Notify about new agent
            broadcast_agent_event(:connected, socket)

            GSMLG.Telemetry.info("Agent connected",
              metadata: %{
                agent_name: agent_name,
                session_id: session_id,
                capabilities: validated_token.capabilities
              }
            )

            {:ok,
             %{
               session_id: session_id,
               capabilities: validated_token.capabilities,
               auto_tags: validated_token.auto_tags
             }, socket}

          {:error, reason} ->
            GSMLG.Telemetry.warn("Failed to create session for agent",
              metadata: %{reason: reason}
            )

            {:error, %{reason: "session_creation_failed"}}
        end

      {:error, :invalid} ->
        GSMLG.Telemetry.warn("Agent connection rejected: invalid token", metadata: %{})
        {:error, %{reason: "invalid_token"}}

      {:error, :expired} ->
        GSMLG.Telemetry.warn("Agent connection rejected: expired token", metadata: %{})
        {:error, %{reason: "token_expired"}}

      {:error, :revoked} ->
        GSMLG.Telemetry.warn("Agent connection rejected: revoked token", metadata: %{})
        {:error, %{reason: "token_revoked"}}
    end
  end

  def join("agent:connect", _params, _socket) do
    {:error, %{reason: "missing_token"}}
  end

  @impl true
  def handle_in("authenticate", %{"metadata" => metadata}, socket) do
    # Update agent metadata after initial connection
    updated_metadata = Map.merge(socket.assigns.agent_metadata, metadata)
    socket = assign(socket, :agent_metadata, updated_metadata)

    # Broadcast updated info
    broadcast_agent_event(:metadata_updated, socket)

    {:reply, {:ok, %{status: "authenticated"}}, socket}
  end

  @impl true
  def handle_in("pty_output", %{"data" => data}, socket) do
    session_id = socket.assigns.session_id

    # Forward to all attached operators
    Phoenix.PubSub.broadcast(
      GSMLG.PubSub,
      "terminal:#{session_id}",
      {:pty_output, %{session_id: session_id, data: data}}
    )

    {:noreply, socket}
  end

  @impl true
  def handle_in(
        "tool_response",
        %{"tool" => tool, "request_id" => request_id, "result" => result},
        socket
      ) do
    session_id = socket.assigns.session_id

    # Forward tool response to operators
    Phoenix.PubSub.broadcast(
      GSMLG.PubSub,
      "tools:#{session_id}",
      {:tool_response, %{tool: tool, request_id: request_id, result: result}}
    )

    {:noreply, socket}
  end

  @impl true
  def handle_in("heartbeat", _payload, socket) do
    socket = assign(socket, :last_heartbeat, System.system_time(:millisecond))
    {:reply, {:ok, %{time: System.system_time(:millisecond)}}, socket}
  end

  @impl true
  def handle_in("resize", %{"rows" => rows, "cols" => cols}, socket) do
    session_id = socket.assigns.session_id
    SessionManager.resize_session(session_id, rows, cols)
    {:noreply, socket}
  end

  @impl true
  def handle_in(event, payload, socket) do
    GSMLG.Telemetry.debug("Unhandled agent channel event",
      metadata: %{event: event, payload: payload}
    )

    {:noreply, socket}
  end

  @impl true
  def handle_info(:check_heartbeat, socket) do
    last_heartbeat = socket.assigns.last_heartbeat
    now = System.system_time(:millisecond)

    if now - last_heartbeat > @heartbeat_timeout do
      GSMLG.Telemetry.warn("Agent heartbeat timeout",
        metadata: %{
          agent_name: socket.assigns.agent_name,
          session_id: socket.assigns.session_id
        }
      )

      {:stop, :heartbeat_timeout, socket}
    else
      schedule_heartbeat_check()
      {:noreply, socket}
    end
  end

  # Handle PTY events from session
  @impl true
  def handle_info({:pty_output, %{data: data}}, socket) do
    push(socket, "pty_output", %{data: data})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:pty_closed, %{exit_code: exit_code}}, socket) do
    push(socket, "pty_closed", %{exit_code: exit_code})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:pty_error, %{reason: reason}}, socket) do
    push(socket, "pty_error", %{reason: reason})
    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(reason, socket) do
    session_id = socket.assigns[:session_id]

    if session_id do
      # Cleanup session
      SessionManager.terminate_session(session_id)

      # Notify about disconnection
      broadcast_agent_event(:disconnected, socket)

      GSMLG.Telemetry.info("Agent disconnected",
        metadata: %{
          agent_name: socket.assigns.agent_name,
          session_id: session_id,
          reason: inspect(reason)
        }
      )
    end

    :ok
  end

  # Private Functions

  defp schedule_heartbeat_check do
    Process.send_after(self(), :check_heartbeat, div(@heartbeat_timeout, 2))
  end

  defp generate_agent_name do
    "agent-#{:rand.uniform(999_999)}"
  end

  defp extract_agent_metadata(params) do
    %{
      hostname: params["hostname"],
      os: params["os"],
      kernel: params["kernel"],
      arch: params["arch"],
      agent_version: params["agent_version"],
      ip_address: params["ip_address"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp broadcast_agent_event(event, socket) do
    Phoenix.PubSub.broadcast(
      GSMLG.PubSub,
      "commanders:events",
      {:commander_event,
       %{
         event: event,
         agent_name: socket.assigns.agent_name,
         session_id: socket.assigns.session_id,
         capabilities: socket.assigns.capabilities,
         tags: socket.assigns.auto_tags,
         metadata: socket.assigns.agent_metadata,
         timestamp: DateTime.utc_now()
       }}
    )
  end
end
