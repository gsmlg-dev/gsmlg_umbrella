defmodule GSMLG.AdminWeb.PTYTerminalLive do
  @moduledoc """
  LiveView for interactive PTY terminal sessions.

  Provides a full-screen terminal interface with xterm.js integration
  for real-time interaction with PTY sessions on remote agents.
  """

  use GSMLG.AdminWeb, :live_view
  alias GSMLG.CommandPlatform.CommandDispatcher

  @impl true
  def mount(%{"agent_id" => agent_id} = params, _session, socket) do
    command = Map.get(params, "command", "/bin/bash")

    # Create PTY session on agent
    case CommandDispatcher.create_pty(agent_id,
           command: command,
           dimensions: %{rows: 24, cols: 80}
         ) do
      {:ok, session_id} ->
        if connected?(socket) do
          # Subscribe to session events
          Phoenix.PubSub.subscribe(GSMLG.PubSub, "pty_session:#{session_id}")
        end

        socket =
          socket
          |> assign(:session_id, session_id)
          |> assign(:agent_id, agent_id)
          |> assign(:command, command)
          |> assign(:session_state, :running)
          |> assign(:page_title, "Terminal - #{agent_id}")

        {:ok, socket}

      {:error, reason} ->
        socket =
          socket
          |> put_flash(:error, "Failed to create PTY session: #{inspect(reason)}")
          |> assign(:error, reason)

        {:ok, socket}
    end
  end

  @impl true
  def handle_event("terminal_mounted", _params, socket) do
    # Terminal is mounted and ready
    {:noreply, socket}
  end

  @impl true
  def handle_event("send_input", %{"data" => data}, socket) do
    CommandDispatcher.send_input(socket.assigns.session_id, data)
    {:noreply, socket}
  end

  @impl true
  def handle_event("resize", %{"rows" => rows, "cols" => cols}, socket) do
    CommandDispatcher.resize_pty(socket.assigns.session_id, rows, cols)
    {:noreply, socket}
  end

  @impl true
  def handle_event("close_session", _params, socket) do
    CommandDispatcher.close_pty(socket.assigns.session_id)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:pty_output, _session_id, data}, socket) do
    {:noreply, push_event(socket, "terminal_output", %{data: data})}
  end

  @impl true
  def handle_info({:pty_closed, _session_id, exit_code, _reason}, socket) do
    socket =
      socket
      |> assign(:session_state, :closed)
      |> push_event("terminal_closed", %{exit_code: exit_code})

    {:noreply, socket}
  end

  @impl true
  def handle_info({:pty_error, _session_id, _error_code, message}, socket) do
    {:noreply, push_event(socket, "terminal_error", %{message: message})}
  end

  @impl true
  def handle_info({:pty_resized, _session_id, rows, cols}, socket) do
    GSMLG.Telemetry.debug("Terminal resized",
      metadata: %{
        session_id: socket.assigns.session_id,
        rows: rows,
        cols: cols
      }
    )

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen flex flex-col">
      <div class="bg-base-200 p-4 flex items-center justify-between">
        <div>
          <h1 class="text-xl font-bold">Terminal Session</h1>
          <p class="text-sm text-base-content/70">
            Agent: {@agent_id} | Command: {@command}
          </p>
        </div>
        <div class="flex gap-2">
          <button
            :if={@session_state == :running}
            phx-click="close_session"
            class="btn btn-error btn-sm"
          >
            Close Session
          </button>
          <.link navigate="/command_platform" class="btn btn-ghost btn-sm">
            Back to Platform
          </.link>
        </div>
      </div>

      <div class="flex-1 p-4 bg-base-100">
        <div
          id="terminal-container"
          phx-hook="Terminal"
          data-session-id={@session_id}
          data-agent-id={@agent_id}
          class="w-full h-full rounded-lg overflow-hidden shadow-xl"
          style="background-color: #1e1e1e;"
        >
        </div>
      </div>
    </div>
    """
  end
end
