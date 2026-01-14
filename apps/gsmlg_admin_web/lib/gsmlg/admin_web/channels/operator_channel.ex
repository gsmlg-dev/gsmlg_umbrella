defmodule GSMLG.AdminWeb.OperatorChannel do
  @moduledoc """
  Phoenix Channel for web UI operator connections.

  Handles WebSocket connections from the web UI for terminal access
  and tool invocations on specific commanders.

  ## Channel Topic

  `operator:terminal:{commander_id}` - Terminal I/O for specific commander

  ## Features

  - Terminal input/output routing
  - Terminal resize handling
  - Tool invocation dispatch
  - Session state synchronization
  """

  # Suppress undefined module warnings for Commander modules (loaded at runtime)
  @compile {:no_warn_undefined, [GSMLG.Commander.SessionManager]}

  use Phoenix.Channel
  require Logger

  alias GSMLG.Commander.SessionManager

  @impl true
  def join("operator:terminal:" <> commander_id, _params, socket) do
    # Verify operator has access (JWT validated in socket)
    user_id = socket.assigns[:user_id]

    case SessionManager.find_session(commander_id) do
      {:ok, _pid} ->
        # Attach operator to session
        case SessionManager.attach_session(commander_id, self()) do
          :ok ->
            # Subscribe to session events
            Phoenix.PubSub.subscribe(GSMLG.PubSub, "terminal:#{commander_id}")
            Phoenix.PubSub.subscribe(GSMLG.PubSub, "tools:#{commander_id}")

            socket =
              socket
              |> assign(:commander_id, commander_id)
              |> assign(:user_id, user_id)
              |> assign(:joined_at, DateTime.utc_now())

            GSMLG.Telemetry.info("Operator joined terminal",
              metadata: %{
                commander_id: commander_id,
                user_id: user_id
              }
            )

            # Get current session info for initial state
            session_info = SessionManager.get_session_info(commander_id)

            {:ok,
             %{
               commander_id: commander_id,
               session_info: session_info,
               status: "connected"
             }, socket}

          {:error, reason} ->
            {:error, %{reason: "attach_failed: #{inspect(reason)}"}}
        end

      {:error, :not_found} ->
        {:error, %{reason: "session_not_found"}}
    end
  end

  @impl true
  def handle_in("input", %{"data" => data}, socket) do
    commander_id = socket.assigns.commander_id

    case SessionManager.send_input(commander_id, data) do
      :ok ->
        {:noreply, socket}

      {:error, reason} ->
        push(socket, "error", %{message: "Failed to send input: #{inspect(reason)}"})
        {:noreply, socket}
    end
  end

  @impl true
  def handle_in("resize", %{"rows" => rows, "cols" => cols}, socket) do
    commander_id = socket.assigns.commander_id

    case SessionManager.resize_session(commander_id, rows, cols) do
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
    commander_id = socket.assigns.commander_id
    request_id = generate_request_id()

    # Forward tool request to agent
    Phoenix.PubSub.broadcast(
      GSMLG.PubSub,
      "agent:#{commander_id}",
      {:tool_request, %{tool: tool, params: params, request_id: request_id}}
    )

    # Reply with request_id for async result tracking
    {:reply, {:ok, %{request_id: request_id}}, socket}
  end

  @impl true
  def handle_in("get_session_info", _params, socket) do
    commander_id = socket.assigns.commander_id
    session_info = SessionManager.get_session_info(commander_id)
    {:reply, {:ok, session_info}, socket}
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
  def handle_info({:pty_closed, %{exit_code: exit_code}}, socket) do
    push(socket, "session_closed", %{exit_code: exit_code})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:pty_error, %{reason: reason}}, socket) do
    push(socket, "error", %{message: "PTY error: #{inspect(reason)}"})
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
    commander_id = socket.assigns[:commander_id]

    if commander_id do
      # Detach operator from session
      SessionManager.detach_session(commander_id)

      GSMLG.Telemetry.info("Operator left terminal",
        metadata: %{
          commander_id: commander_id,
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
end
