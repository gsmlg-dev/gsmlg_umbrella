defmodule GSMLG.AdminWeb.CommanderLive.ShowLive do
  @moduledoc """
  LiveView for commander detail page with tabs.

  Shows detailed information about a specific commander including:
  - Overview (status, host info, capabilities)
  - Shell (terminal access)
  - Files (file browser)
  - Processes (process manager)
  - Logs (log viewer)
  - Metrics (system metrics)
  """

  use GSMLG.AdminWeb, :live_view

  alias GSMLG.CommandPlatform.{AgentRegistry, CommandDispatcher}
  alias Phoenix.LiveView.AsyncResult

  @impl true
  def mount(%{"name" => commander_name}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GSMLG.PubSub, "commander_updates")
    end

    socket =
      socket
      |> assign(:page_title, "Commander")
      |> assign(:commander_id, commander_name)
      |> assign(:commander_name, commander_name)
      |> assign(:commander, AsyncResult.loading())
      |> assign(:tab, :overview)
      |> assign(:terminals, [])
      |> assign(:active_terminal, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply,
     socket
     |> assign(:tab, tab_from_params(params, socket.assigns.live_action))
     |> fetch_commander()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} active_menu="commander_list">
      <% commander = loaded_commander(@commander) %>
      <div class="p-6">
        <%= if async_loading?(@commander) do %>
          <div class="flex items-center justify-center h-64">
            <div class="animate-spin rounded-full h-12 w-12 border-b-2 border-blue-500"></div>
          </div>
        <% else %>
          <%= if commander do %>
            <!-- Header -->
            <div class="mb-6 flex items-center justify-between">
              <div class="flex items-center space-x-4">
                <.link
                  navigate={~p"/commander/list"}
                  class="text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"
                >
                  <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M10 19l-7-7m0 0l7-7m-7 7h18"
                    />
                  </svg>
                </.link>
                <div>
                  <h1 class="text-2xl font-bold text-gray-900 dark:text-white">
                    {commander.hostname}
                  </h1>
                  <p class="text-sm text-gray-500 dark:text-gray-400">
                    {commander.id}
                  </p>
                </div>
              </div>
              <div class="flex items-center space-x-3">
                <.status_badge status={commander.status} />
                <button
                  phx-click="refresh"
                  class="p-2 text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200 border border-gray-300 dark:border-gray-600 rounded-md"
                >
                  <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"
                    />
                  </svg>
                </button>
              </div>
            </div>

            <!-- Tabs -->
            <div class="mb-6 border-b border-gray-200 dark:border-gray-700">
              <nav class="-mb-px flex space-x-8">
                <.tab_link tab={:overview} current={@tab} commander_id={@commander_id}>
                  Overview
                </.tab_link>
                <%= if :shell in commander.capabilities do %>
                  <.tab_link tab={:shell} current={@tab} commander_id={@commander_id}>
                    Shell
                  </.tab_link>
                <% else %>
                  <span
                    class="border-transparent text-gray-400 dark:text-gray-600 whitespace-nowrap py-4 px-1 border-b-2 font-medium text-sm cursor-not-allowed"
                    title="Shell not available"
                  >
                    Shell
                  </span>
                <% end %>
              </nav>
            </div>

            <!-- Tab Content -->
            <div class="bg-white dark:bg-gray-800 rounded-lg shadow-md">
              <%= case @tab do %>
                <% :overview -> %>
                  <.overview_tab commander={commander} />
                <% :shell -> %>
                  <.shell_tab
                    commander={commander}
                    terminals={@terminals}
                    active_terminal={@active_terminal}
                  />
                <% _ -> %>
                  <div class="p-6 text-center text-gray-500">Tab not available</div>
              <% end %>
            </div>
          <% else %>
            <div class="text-center py-12">
              <svg
                class="mx-auto h-12 w-12 text-gray-400"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M9.172 16.172a4 4 0 015.656 0M9 10h.01M15 10h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                />
              </svg>
              <h3 class="mt-2 text-lg font-medium text-gray-900 dark:text-white">
                Commander not found
              </h3>
              <p class="mt-1 text-gray-500 dark:text-gray-400">
                The commander may have disconnected.
              </p>
              <div class="mt-6">
                <.link navigate={~p"/commander/list"} class="text-blue-600 hover:text-blue-800">
                  Back to Commander List
                </.link>
              </div>
            </div>
          <% end %>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # Event Handlers

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, fetch_commander(socket)}
  end

  @impl true
  def handle_event("new_terminal", _params, socket) do
    case CommandDispatcher.create_pty(socket.assigns.commander_id,
           command: "/bin/bash",
           dimensions: %{rows: 24, cols: 80}
         ) do
      {:ok, terminal_id} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(GSMLG.PubSub, "pty_session:#{terminal_id}")
        end

        terminal = %{
          id: terminal_id,
          title: "bash ##{length(socket.assigns.terminals) + 1}",
          command: "/bin/bash",
          dimensions: %{rows: 24, cols: 80},
          state: :initializing,
          created_at: DateTime.utc_now()
        }

        terminals = socket.assigns.terminals ++ [terminal]

        {:noreply,
         socket
         |> assign(:terminals, terminals)
         |> assign(:active_terminal, terminal_id)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start terminal: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("select_terminal", %{"id" => id}, socket) do
    {:noreply, assign(socket, :active_terminal, id)}
  end

  @impl true
  def handle_event("close_terminal", %{"id" => id}, socket) do
    CommandDispatcher.close_pty(id, false, agent_id: socket.assigns.commander_id)

    terminals = Enum.reject(socket.assigns.terminals, &(&1.id == id))

    active_terminal =
      if socket.assigns.active_terminal == id do
        case terminals do
          [] -> nil
          [first | _] -> first.id
        end
      else
        socket.assigns.active_terminal
      end

    {:noreply,
     socket
     |> assign(:terminals, terminals)
     |> assign(:active_terminal, active_terminal)}
  end

  @impl true
  def handle_event("terminal_mounted", %{"session_id" => _session_id}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:commander_event, %{session_id: session_id}}, socket)
      when session_id == socket.assigns.commander_id do
    {:noreply, fetch_commander(socket)}
  end

  @impl true
  def handle_info(:commander_updates, socket) do
    {:noreply, fetch_commander(socket)}
  end

  @impl true
  def handle_info(
        {:agent_registered, commander_id, _info},
        %{assigns: %{commander_id: commander_id}} = socket
      ) do
    {:noreply, fetch_commander(socket)}
  end

  @impl true
  def handle_info(
        {:agent_disconnected, commander_id},
        %{assigns: %{commander_id: commander_id}} = socket
      ) do
    {:noreply, fetch_commander(socket)}
  end

  @impl true
  def handle_info({:pty_created, session_id, _session_info}, socket) do
    terminals =
      Enum.map(socket.assigns.terminals, fn
        %{id: ^session_id} = terminal -> %{terminal | state: :running}
        terminal -> terminal
      end)

    {:noreply, assign(socket, :terminals, terminals)}
  end

  @impl true
  def handle_info({:pty_output, %{data: data}}, socket) do
    # Forward to terminal via JS hook
    {:noreply, push_event(socket, "terminal_output", %{data: data})}
  end

  @impl true
  def handle_info({:pty_output, session_id, data}, socket) do
    terminals =
      Enum.map(socket.assigns.terminals, fn
        %{id: ^session_id} = terminal -> %{terminal | state: :running}
        terminal -> terminal
      end)

    {:noreply,
     socket
     |> assign(:terminals, terminals)
     |> push_event("terminal_output", %{data: data})}
  end

  @impl true
  def handle_info({:pty_closed, %{exit_code: exit_code}}, socket) do
    {:noreply, push_event(socket, "terminal_closed", %{exit_code: exit_code})}
  end

  @impl true
  def handle_info({:pty_closed, session_id, exit_code, _reason}, socket) do
    terminals =
      Enum.map(socket.assigns.terminals, fn
        %{id: ^session_id} = terminal -> %{terminal | state: :closed}
        terminal -> terminal
      end)

    {:noreply,
     socket
     |> assign(:terminals, terminals)
     |> push_event("terminal_closed", %{exit_code: exit_code})}
  end

  @impl true
  def handle_info({:pty_error, session_id, _error_code, message}, socket) do
    terminals =
      Enum.map(socket.assigns.terminals, fn
        %{id: ^session_id} = terminal -> %{terminal | state: :error}
        terminal -> terminal
      end)

    {:noreply,
     socket
     |> assign(:terminals, terminals)
     |> push_event("terminal_error", %{message: message})}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Private Functions

  defp fetch_commander(socket) do
    commander_id = socket.assigns.commander_id

    assign_async(
      socket,
      :commander,
      fn -> {:ok, %{commander: load_commander(commander_id)}} end,
      reset: true
    )
  end

  defp load_commander(commander_id) do
    case AgentRegistry.find_agent(commander_id) do
      {:error, _} -> nil
      {:ok, agent} -> format_commander(agent)
    end
  rescue
    _ -> nil
  end

  defp loaded_commander(%AsyncResult{ok?: true, result: commander}), do: commander
  defp loaded_commander(_), do: nil

  defp async_loading?(%AsyncResult{loading: loading}), do: loading not in [nil, false]
  defp async_loading?(_), do: false

  defp format_commander(agent) do
    info = Map.get(agent, :info, %{})
    metadata = Map.drop(info, [:capabilities, :hostname, :sessions])

    %{
      id: agent.agent_id,
      hostname: value(info, :hostname) || agent.agent_id,
      status: agent.status,
      capabilities: normalize_capabilities(value(info, :capabilities)),
      tags: value(info, :tags) || [],
      connected_at: agent.connected_at,
      last_activity: agent.last_heartbeat,
      uptime: agent.last_heartbeat - agent.connected_at,
      dimensions: %{rows: 24, cols: 80},
      metadata: metadata
    }
  end

  defp tab_from_params(%{"tab" => tab}, _live_action), do: tab_from_string(tab)
  defp tab_from_params(_params, :overview), do: :overview
  defp tab_from_params(_params, :shell), do: :shell
  defp tab_from_params(_params, _live_action), do: :overview

  defp tab_from_string("shell"), do: :shell
  defp tab_from_string("files"), do: :files
  defp tab_from_string("processes"), do: :processes
  defp tab_from_string("logs"), do: :logs
  defp tab_from_string("metrics"), do: :metrics
  defp tab_from_string(_), do: :overview

  defp commander_tab_path(commander_id, :shell), do: ~p"/commander/#{commander_id}/shell"
  defp commander_tab_path(commander_id, _tab), do: ~p"/commander/#{commander_id}/overview"

  defp normalize_capabilities(nil), do: [:shell]

  defp normalize_capabilities(capabilities) do
    capabilities
    |> Enum.map(fn
      capability when is_atom(capability) -> capability
      capability when is_binary(capability) -> capability_from_string(capability)
    end)
    |> Enum.uniq()
  end

  defp capability_from_string("pty"), do: :shell
  defp capability_from_string("shell"), do: :shell
  defp capability_from_string("resize"), do: :resize
  defp capability_from_string("files"), do: :files
  defp capability_from_string("processes"), do: :processes
  defp capability_from_string("logs"), do: :logs
  defp capability_from_string("metrics"), do: :metrics
  defp capability_from_string("system_info"), do: :system_info
  defp capability_from_string(_), do: :unknown

  defp value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  # Components

  defp status_badge(assigns) do
    {bg_color, text_color, label} =
      case assigns.status do
        :running ->
          {"bg-green-100 dark:bg-green-900", "text-green-800 dark:text-green-200", "Active"}

        :attached ->
          {"bg-green-100 dark:bg-green-900", "text-green-800 dark:text-green-200", "Attached"}

        :detached ->
          {"bg-yellow-100 dark:bg-yellow-900", "text-yellow-800 dark:text-yellow-200", "Detached"}

        :initializing ->
          {"bg-blue-100 dark:bg-blue-900", "text-blue-800 dark:text-blue-200", "Pending"}

        :closing ->
          {"bg-red-100 dark:bg-red-900", "text-red-800 dark:text-red-200", "Closing"}

        _ ->
          {"bg-gray-100 dark:bg-gray-700", "text-gray-800 dark:text-gray-200",
           to_string(assigns.status)}
      end

    assigns = assign(assigns, bg_color: bg_color, text_color: text_color, label: label)

    ~H"""
    <span class={"inline-flex items-center px-3 py-1 rounded-full text-sm font-medium #{@bg_color} #{@text_color}"}>
      {@label}
    </span>
    """
  end

  slot :inner_block, required: true
  attr :tab, :atom, required: true
  attr :current, :atom, required: true
  attr :commander_id, :string, required: true

  defp tab_link(assigns) do
    active_class =
      "border-blue-500 text-blue-600 dark:text-blue-400"

    inactive_class =
      "border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300 dark:text-gray-400 dark:hover:text-gray-200"

    class =
      if assigns.tab == assigns.current, do: active_class, else: inactive_class

    assigns = assign(assigns, :class, class)

    ~H"""
    <.link
      patch={commander_tab_path(@commander_id, @tab)}
      class={"whitespace-nowrap py-4 px-1 border-b-2 font-medium text-sm #{@class}"}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  defp overview_tab(assigns) do
    ~H"""
    <div class="p-6 space-y-6">
      <!-- Status & Connection -->
      <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
        <div class="border border-gray-200 dark:border-gray-700 rounded-lg p-4">
          <h3 class="text-lg font-medium text-gray-900 dark:text-white mb-4">
            Status & Connection
          </h3>
          <dl class="space-y-3">
            <div class="flex justify-between">
              <dt class="text-gray-500 dark:text-gray-400">Status</dt>
              <dd><.status_badge status={@commander.status} /></dd>
            </div>
            <div class="flex justify-between">
              <dt class="text-gray-500 dark:text-gray-400">Session ID</dt>
              <dd class="font-mono text-sm text-gray-900 dark:text-white">{@commander.id}</dd>
            </div>
            <div class="flex justify-between">
              <dt class="text-gray-500 dark:text-gray-400">Connected</dt>
              <dd class="text-gray-900 dark:text-white">
                {format_datetime(@commander.connected_at)}
              </dd>
            </div>
            <div class="flex justify-between">
              <dt class="text-gray-500 dark:text-gray-400">Last Activity</dt>
              <dd class="text-gray-900 dark:text-white">
                {format_datetime(@commander.last_activity)}
              </dd>
            </div>
            <%= if @commander.uptime do %>
              <div class="flex justify-between">
                <dt class="text-gray-500 dark:text-gray-400">Uptime</dt>
                <dd class="text-gray-900 dark:text-white">{format_uptime(@commander.uptime)}</dd>
              </div>
            <% end %>
          </dl>
        </div>

        <div class="border border-gray-200 dark:border-gray-700 rounded-lg p-4">
          <h3 class="text-lg font-medium text-gray-900 dark:text-white mb-4">
            Host Information
          </h3>
          <dl class="space-y-3">
            <div class="flex justify-between">
              <dt class="text-gray-500 dark:text-gray-400">Hostname</dt>
              <dd class="text-gray-900 dark:text-white">{@commander.hostname}</dd>
            </div>
            <%= if @commander.metadata[:os] do %>
              <div class="flex justify-between">
                <dt class="text-gray-500 dark:text-gray-400">OS</dt>
                <dd class="text-gray-900 dark:text-white">{@commander.metadata[:os]}</dd>
              </div>
            <% end %>
            <%= if @commander.metadata[:kernel] do %>
              <div class="flex justify-between">
                <dt class="text-gray-500 dark:text-gray-400">Kernel</dt>
                <dd class="text-gray-900 dark:text-white">{@commander.metadata[:kernel]}</dd>
              </div>
            <% end %>
            <%= if @commander.metadata[:arch] do %>
              <div class="flex justify-between">
                <dt class="text-gray-500 dark:text-gray-400">Architecture</dt>
                <dd class="text-gray-900 dark:text-white">{@commander.metadata[:arch]}</dd>
              </div>
            <% end %>
            <%= if @commander.metadata[:ip_address] do %>
              <div class="flex justify-between">
                <dt class="text-gray-500 dark:text-gray-400">IP Address</dt>
                <dd class="text-gray-900 dark:text-white">{@commander.metadata[:ip_address]}</dd>
              </div>
            <% end %>
          </dl>
        </div>
      </div>

      <!-- Capabilities -->
      <div class="border border-gray-200 dark:border-gray-700 rounded-lg p-4">
        <h3 class="text-lg font-medium text-gray-900 dark:text-white mb-4">
          Capabilities
        </h3>
        <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
          <%= for cap <- [:shell, :files, :processes, :system_info, :logs, :metrics, :services] do %>
            <.capability_card capability={cap} enabled={cap in @commander.capabilities} />
          <% end %>
        </div>
      </div>

      <!-- Tags -->
      <div class="border border-gray-200 dark:border-gray-700 rounded-lg p-4">
        <h3 class="text-lg font-medium text-gray-900 dark:text-white mb-4">Tags</h3>
        <div class="flex flex-wrap gap-2">
          <%= for tag <- @commander.tags do %>
            <span class="px-3 py-1 bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300 text-sm rounded-full">
              {tag}
            </span>
          <% end %>
          <%= if @commander.tags == [] do %>
            <span class="text-gray-500 dark:text-gray-400">No tags assigned</span>
          <% end %>
        </div>
      </div>

      <!-- Quick Actions -->
      <div class="border border-gray-200 dark:border-gray-700 rounded-lg p-4">
        <h3 class="text-lg font-medium text-gray-900 dark:text-white mb-4">Quick Actions</h3>
        <div class="flex flex-wrap gap-3">
          <%= if :shell in @commander.capabilities do %>
            <.link
              patch={~p"/commander/#{@commander.id}/shell"}
              class="inline-flex items-center px-4 py-2 bg-green-600 text-white rounded-md hover:bg-green-700"
            >
              <svg class="w-5 h-5 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M8 9l3 3-3 3m5 0h3M5 20h14a2 2 0 002-2V6a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"
                />
              </svg>
              Open Shell
            </.link>
          <% end %>
          <button class="inline-flex items-center px-4 py-2 border border-red-300 dark:border-red-600 text-red-600 dark:text-red-400 rounded-md hover:bg-red-50 dark:hover:bg-red-900/20">
            <svg class="w-5 h-5 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M17 16l4-4m0 0l-4-4m4 4H7m6 4v1a3 3 0 01-3 3H6a3 3 0 01-3-3V7a3 3 0 013-3h4a3 3 0 013 3v1"
              />
            </svg>
            Disconnect
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp shell_tab(assigns) do
    ~H"""
    <div class="p-4">
      <!-- Terminal Tabs -->
      <div class="flex items-center space-x-2 mb-4 border-b border-gray-200 dark:border-gray-700 pb-2">
        <%= for terminal <- @terminals do %>
          <button
            phx-click="select_terminal"
            phx-value-id={terminal.id}
            class={"px-3 py-1.5 rounded-t-md text-sm flex items-center space-x-2 " <>
              if terminal.id == @active_terminal do
                "bg-gray-100 dark:bg-gray-700 text-gray-900 dark:text-white"
              else
                "text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"
              end}
          >
            <span>{terminal.title}</span>
            <button
              phx-click="close_terminal"
              phx-value-id={terminal.id}
              class="ml-2 text-gray-400 hover:text-red-500"
            >
              x
            </button>
          </button>
        <% end %>
        <button
          phx-click="new_terminal"
          class="px-3 py-1.5 text-sm text-blue-600 hover:text-blue-800 dark:text-blue-400 dark:hover:text-blue-300"
        >
          + New Session
        </button>
      </div>

      <!-- Terminal Container -->
      <%= if @active_terminal do %>
        <% terminal = Enum.find(@terminals, &(&1.id == @active_terminal)) %>
        <div
          id={"terminal-#{@active_terminal}"}
          phx-hook="Terminal"
          phx-update="ignore"
          data-session-id={terminal.id}
          data-agent-id={@commander.id}
          class="h-96 bg-gray-900 rounded-md overflow-hidden"
        >
        </div>
        <div class="mt-2 flex items-center justify-between text-xs text-gray-500 dark:text-gray-400">
          <div class="flex space-x-4">
            <span>Ctrl+C</span>
            <span>Ctrl+D</span>
          </div>
          <div class="flex space-x-4">
            <span>{terminal.dimensions.cols}x{terminal.dimensions.rows}</span>
            <span>{terminal.command}</span>
            <span>{terminal.state}</span>
            <span>UTF-8</span>
          </div>
        </div>
      <% else %>
        <div class="h-96 bg-gray-100 dark:bg-gray-700 rounded-md flex items-center justify-center">
          <div class="text-center">
            <svg
              class="mx-auto h-12 w-12 text-gray-400"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M8 9l3 3-3 3m5 0h3M5 20h14a2 2 0 002-2V6a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"
              />
            </svg>
            <p class="mt-2 text-gray-500 dark:text-gray-400">
              Click "New Session" to start a terminal
            </p>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp capability_card(assigns) do
    {icon, label} =
      case assigns.capability do
        :shell -> {"terminal", "Shell"}
        :files -> {"folder", "File Browser"}
        :processes -> {"cpu", "Process Manager"}
        :system_info -> {"info", "System Info"}
        :logs -> {"document", "Log Viewer"}
        :metrics -> {"chart", "Metrics"}
        :services -> {"cog", "Service Manager"}
        _ -> {"question", to_string(assigns.capability)}
      end

    assigns = assign(assigns, icon: icon, label: label)

    ~H"""
    <div class={"p-3 rounded-lg border " <>
      if @enabled do
        "border-green-200 bg-green-50 dark:border-green-800 dark:bg-green-900/20"
      else
        "border-gray-200 bg-gray-50 dark:border-gray-700 dark:bg-gray-800/50"
      end}>
      <div class="flex items-center space-x-2">
        <div class={"w-8 h-8 rounded-full flex items-center justify-center " <>
          if @enabled do
            "bg-green-100 dark:bg-green-800"
          else
            "bg-gray-100 dark:bg-gray-700"
          end}>
          <.cap_icon name={@icon} enabled={@enabled} />
        </div>
        <div>
          <p class={"text-sm font-medium " <>
            if @enabled do
              "text-green-800 dark:text-green-200"
            else
              "text-gray-500 dark:text-gray-400"
            end}>
            {@label}
          </p>
          <p class={"text-xs " <>
            if @enabled do
              "text-green-600 dark:text-green-400"
            else
              "text-gray-400 dark:text-gray-500"
            end}>
            {if @enabled, do: "Supported", else: "Not available"}
          </p>
        </div>
      </div>
    </div>
    """
  end

  defp cap_icon(%{name: "terminal", enabled: enabled} = assigns) do
    color = if enabled, do: "text-green-600 dark:text-green-400", else: "text-gray-400"
    assigns = assign(assigns, :color, color)

    ~H"""
    <svg class={"w-4 h-4 #{@color}"} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M8 9l3 3-3 3m5 0h3M5 20h14a2 2 0 002-2V6a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"
      />
    </svg>
    """
  end

  defp cap_icon(%{name: "folder", enabled: enabled} = assigns) do
    color = if enabled, do: "text-green-600 dark:text-green-400", else: "text-gray-400"
    assigns = assign(assigns, :color, color)

    ~H"""
    <svg class={"w-4 h-4 #{@color}"} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z"
      />
    </svg>
    """
  end

  defp cap_icon(%{enabled: enabled} = assigns) do
    color = if enabled, do: "text-green-600 dark:text-green-400", else: "text-gray-400"
    assigns = assign(assigns, :color, color)

    ~H"""
    <svg class={"w-4 h-4 #{@color}"} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M13 10V3L4 14h7v7l9-11h-7z"
      />
    </svg>
    """
  end

  defp format_datetime(nil), do: "-"

  defp format_datetime(ts) when is_integer(ts) do
    DateTime.from_unix!(div(ts, 1000))
    |> Calendar.strftime("%b %d, %Y %H:%M")
  end

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %Y %H:%M")
  end

  defp format_datetime(_), do: "-"

  defp format_uptime(ms) when is_integer(ms) do
    seconds = div(ms, 1000)
    minutes = div(seconds, 60)
    hours = div(minutes, 60)
    days = div(hours, 24)

    cond do
      days > 0 -> "#{days}d #{rem(hours, 24)}h"
      hours > 0 -> "#{hours}h #{rem(minutes, 60)}m"
      minutes > 0 -> "#{minutes}m #{rem(seconds, 60)}s"
      true -> "#{seconds}s"
    end
  end

  defp format_uptime(_), do: "-"
end
