defmodule GSMLG.AdminWeb.OperatorChannel do
  @moduledoc """
  Phoenix Channel for web UI operator connections.

  Handles WebSocket connections from the web UI for terminal access
  and tool invocations on specific commanders.

  ## Channel Topic

  `operator:terminal:{session_id}` - Terminal I/O for a specific PTY session

  ## Features

  - Terminal input/output routing
  - Terminal resize handling
  - Tool invocation dispatch
  - Session state synchronization
  """

  use Phoenix.Channel
  require Logger

  alias GSMLG.CommandPlatform.{CommandDispatcher, SessionTracker}

  @impl true
  def join("operator:terminal:" <> session_id, params, socket) do
    # Verify operator has access (JWT validated in socket)
    user_id = socket.assigns[:user_id]

    agent_id = params["agent_id"]

    case CommandDispatcher.attach_pty(session_id, self(), agent_id: agent_id) do
      :ok ->
        # Subscribe to session events
        Phoenix.PubSub.subscribe(GSMLG.PubSub, "pty_session:#{session_id}")
        Phoenix.PubSub.subscribe(GSMLG.PubSub, "tools:#{session_id}")

        socket =
          socket
          |> assign(:session_id, session_id)
          |> assign(:agent_id, agent_id)
          |> assign(:user_id, user_id)
          |> assign(:joined_at, DateTime.utc_now())

        GSMLG.Telemetry.info("Operator joined terminal",
          metadata: %{
            session_id: session_id,
            agent_id: agent_id,
            user_id: user_id
          }
        )

        {:ok,
         %{
           session_id: session_id,
           session_info: session_info(session_id, agent_id),
           status: "connected"
         }, socket}

      {:error, :not_found} ->
        {:error, %{reason: "session_not_found"}}

      {:error, reason} ->
        {:error, %{reason: "attach_failed: #{inspect(reason)}"}}
    end
  end

  @impl true
  def handle_in("input", %{"data" => data}, socket) do
    session_id = socket.assigns.session_id

    case CommandDispatcher.send_input(session_id, data, agent_id: socket.assigns.agent_id) do
      :ok ->
        {:noreply, socket}

      {:error, reason} ->
        push(socket, "error", %{message: "Failed to send input: #{inspect(reason)}"})
        {:noreply, socket}
    end
  end

  @impl true
  def handle_in("resize", %{"rows" => rows, "cols" => cols}, socket) do
    session_id = socket.assigns.session_id

    case CommandDispatcher.resize_pty(session_id, rows, cols, agent_id: socket.assigns.agent_id) do
      :ok ->
        push(socket, "resized", %{rows: rows, cols: cols})
        {:noreply, socket}

      {:error, reason} ->
        push(socket, "error", %{message: "Failed to resize: #{inspect(reason)}"})
        {:noreply, socket}
    end
  end

  @impl true
  def handle_in("invoke_tool", %{"tool" => tool, "params" => params}, socket) do
    session_id = socket.assigns.session_id
    request_id = generate_request_id()

    # Forward tool request to agent
    Phoenix.PubSub.broadcast(
      GSMLG.PubSub,
      "pty_session:#{session_id}:tools",
      {:tool_request, %{tool: tool, params: params, request_id: request_id}}
    )

    # Reply with request_id for async result tracking
    {:reply, {:ok, %{request_id: request_id}}, socket}
  end

  @impl true
  def handle_in("get_session_info", _params, socket) do
    {:reply, {:ok, session_info(socket.assigns.session_id)}, socket}
  end

  @impl true
  def handle_in(event, payload, socket) do
    GSMLG.Telemetry.debug("Unhandled operator channel event",
      metadata: %{event: event, payload: payload}
    )

    {:noreply, socket}
  end

  # Handle PubSub messages from session

  @impl true
  def handle_info({:pty_output, %{data: data}}, socket) do
    push(socket, "output", %{data: Base.encode64(data)})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:pty_output, session_id, data}, %{assigns: %{session_id: session_id}} = socket) do
    push(socket, "output", %{data: Base.encode64(data)})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:pty_closed, %{exit_code: exit_code}}, socket) do
    push(socket, "session_closed", %{exit_code: exit_code})
    {:noreply, socket}
  end

  @impl true
  def handle_info(
        {:pty_closed, session_id, exit_code, _reason},
        %{assigns: %{session_id: session_id}} = socket
      ) do
    push(socket, "session_closed", %{exit_code: exit_code})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:pty_error, %{reason: reason}}, socket) do
    push(socket, "error", %{message: "PTY error: #{inspect(reason)}"})
    {:noreply, socket}
  end

  @impl true
  def handle_info(
        {:pty_error, session_id, _error_code, message},
        %{assigns: %{session_id: session_id}} = socket
      ) do
    push(socket, "error", %{message: message})
    {:noreply, socket}
  end

  @impl true
  def handle_info(
        {:pty_resized, session_id, rows, cols},
        %{assigns: %{session_id: session_id}} = socket
      ) do
    push(socket, "resized", %{rows: rows, cols: cols})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:tool_response, %{tool: tool, request_id: request_id, result: result}}, socket) do
    push(socket, "tool_result", %{
      tool: tool,
      request_id: request_id,
      result: result
    })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:commander_event, event}, socket) do
    push(socket, "commander_update", event)
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
      # Detach operator from session
      CommandDispatcher.detach_pty(session_id, agent_id: socket.assigns[:agent_id])

      GSMLG.Telemetry.info("Operator left terminal",
        metadata: %{
          session_id: session_id,
          agent_id: socket.assigns[:agent_id],
          user_id: socket.assigns[:user_id],
          reason: inspect(reason)
        }
      )
    end

    :ok
  end

  # Private Functions

  defp generate_request_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp session_info(session_id, agent_id) when is_binary(agent_id) and agent_id != "" do
    %{
      session_id: session_id,
      agent_id: agent_id
    }
  end

  defp session_info(session_id, _agent_id) do
    session_info(session_id)
  end

  defp session_info(session_id) do
    case SessionTracker.find_session(session_id) do
      {:ok, session} -> session
      {:error, reason} -> %{error: reason}
    end
  end
end
