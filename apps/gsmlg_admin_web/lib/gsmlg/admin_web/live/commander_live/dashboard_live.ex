defmodule GSMLG.AdminWeb.CommanderLive.DashboardLive do
  @moduledoc """
  LiveView for the commander management dashboard.

  Displays aggregate statistics, recent activity, and status charts
  for all connected commanders.
  """

  use GSMLG.AdminWeb, :live_view

  alias GSMLG.Commander.{SessionManager, TokenManager}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GSMLG.PubSub, "commanders:events")
      # Refresh stats every 30 seconds
      :timer.send_interval(:timer.seconds(30), self(), :refresh_stats)
    end

    {:ok,
     socket
     |> assign(:page_title, "Commander Dashboard")
     |> assign(:stats, default_stats())
     |> assign(:recent_activity, [])
     |> assign(:by_tag, %{})
     |> assign(:alerts, [])
     |> fetch_dashboard_data()}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6">
      <div class="mb-6">
        <h1 class="text-2xl font-bold text-gray-900 dark:text-white">Commander Dashboard</h1>
        <p class="mt-1 text-gray-600 dark:text-gray-400">
          Overview of all connected commander agents
        </p>
      </div>

      <!-- Stats Cards -->
      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4 mb-6">
        <.stats_card
          title="Total Commanders"
          value={@stats.total}
          trend={"+#{@stats.new_today} today"}
          color="blue"
          icon="server"
        />
        <.stats_card
          title="Active Now"
          value={@stats.active}
          trend={trend_text(@stats.active, @stats.total)}
          color="green"
          icon="signal"
        />
        <.stats_card
          title="Disconnected"
          value={@stats.disconnected}
          trend=""
          color="yellow"
          icon="offline"
        />
        <.stats_card
          title="Active Tokens"
          value={@stats.active_tokens}
          trend=""
          color="purple"
          icon="key"
        />
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <!-- Recent Activity -->
        <div class="bg-white dark:bg-gray-800 rounded-lg shadow-md">
          <div class="px-6 py-4 border-b border-gray-200 dark:border-gray-700">
            <h2 class="text-lg font-semibold text-gray-900 dark:text-white">Recent Activity</h2>
          </div>
          <div class="divide-y divide-gray-200 dark:divide-gray-700 max-h-96 overflow-y-auto">
            <%= for activity <- @recent_activity do %>
              <div class="px-6 py-4 flex items-start">
                <div class={"flex-shrink-0 w-2 h-2 mt-2 rounded-full #{activity_color(activity.event)}"}>
                </div>
                <div class="ml-3 flex-1">
                  <p class="text-sm text-gray-900 dark:text-white">
                    <span class="font-medium"><%= activity.agent_name %></span>
                    <%= activity_text(activity.event) %>
                  </p>
                  <p class="text-xs text-gray-500 dark:text-gray-400 mt-1">
                    <%= format_time_ago(activity.timestamp) %>
                  </p>
                </div>
              </div>
            <% end %>
            <%= if Enum.empty?(@recent_activity) do %>
              <div class="px-6 py-8 text-center text-gray-500 dark:text-gray-400">
                No recent activity
              </div>
            <% end %>
          </div>
        </div>

        <!-- Commanders by Tag -->
        <div class="bg-white dark:bg-gray-800 rounded-lg shadow-md">
          <div class="px-6 py-4 border-b border-gray-200 dark:border-gray-700">
            <h2 class="text-lg font-semibold text-gray-900 dark:text-white">Commanders by Tag</h2>
          </div>
          <div class="p-6">
            <%= if map_size(@by_tag) > 0 do %>
              <div class="space-y-4">
                <%= for {tag, count} <- @by_tag |> Enum.sort_by(fn {_, c} -> -c end) |> Enum.take(10) do %>
                  <div class="flex items-center">
                    <span class="w-24 text-sm text-gray-600 dark:text-gray-400 truncate">
                      <%= tag %>
                    </span>
                    <div class="flex-1 mx-4">
                      <div class="h-4 bg-gray-200 dark:bg-gray-700 rounded-full overflow-hidden">
                        <div
                          class="h-full bg-blue-500"
                          style={"width: #{tag_percentage(count, @stats.total)}%"}
                        >
                        </div>
                      </div>
                    </div>
                    <span class="w-12 text-right text-sm font-medium text-gray-900 dark:text-white">
                      <%= count %>
                    </span>
                  </div>
                <% end %>
              </div>
            <% else %>
              <div class="text-center text-gray-500 dark:text-gray-400 py-8">
                No tagged commanders
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <!-- Quick Actions -->
      <div class="mt-6 bg-white dark:bg-gray-800 rounded-lg shadow-md p-6">
        <h2 class="text-lg font-semibold text-gray-900 dark:text-white mb-4">Quick Actions</h2>
        <div class="flex flex-wrap gap-4">
          <.link
            navigate={~p"/commander/list"}
            class="inline-flex items-center px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700 transition-colors"
          >
            <svg class="w-5 h-5 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M4 6h16M4 10h16M4 14h16M4 18h16"
              />
            </svg>
            View All Commanders
          </.link>
          <.link
            navigate={~p"/commander/tokens"}
            class="inline-flex items-center px-4 py-2 bg-purple-600 text-white rounded-md hover:bg-purple-700 transition-colors"
          >
            <svg class="w-5 h-5 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"
              />
            </svg>
            Manage Tokens
          </.link>
          <button
            phx-click="refresh"
            class="inline-flex items-center px-4 py-2 border border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-300 rounded-md hover:bg-gray-50 dark:hover:bg-gray-700 transition-colors"
          >
            <svg class="w-5 h-5 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"
              />
            </svg>
            Refresh
          </button>
        </div>
      </div>

      <!-- Alerts Section -->
      <%= if length(@alerts) > 0 do %>
        <div class="mt-6 bg-red-50 dark:bg-red-900/20 border-l-4 border-red-400 p-4 rounded">
          <div class="flex">
            <div class="flex-shrink-0">
              <svg class="h-5 w-5 text-red-400" viewBox="0 0 20 20" fill="currentColor">
                <path
                  fill-rule="evenodd"
                  d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z"
                  clip-rule="evenodd"
                />
              </svg>
            </div>
            <div class="ml-3">
              <h3 class="text-sm font-medium text-red-800 dark:text-red-200">
                <%= length(@alerts) %> Alert(s)
              </h3>
              <div class="mt-2 text-sm text-red-700 dark:text-red-300">
                <ul class="list-disc pl-5 space-y-1">
                  <%= for alert <- @alerts do %>
                    <li><%= alert.message %></li>
                  <% end %>
                </ul>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # Event Handlers

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, fetch_dashboard_data(socket)}
  end

  @impl true
  def handle_info(:refresh_stats, socket) do
    {:noreply, fetch_dashboard_data(socket)}
  end

  @impl true
  def handle_info({:commander_event, event}, socket) do
    # Add to recent activity
    activity = %{
      event: event.event,
      agent_name: event.agent_name,
      session_id: event.session_id,
      timestamp: event.timestamp || DateTime.utc_now()
    }

    recent_activity =
      [activity | socket.assigns.recent_activity]
      |> Enum.take(20)

    # Refresh stats
    socket =
      socket
      |> assign(:recent_activity, recent_activity)
      |> fetch_stats()

    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Private Functions

  defp fetch_dashboard_data(socket) do
    socket
    |> fetch_stats()
    |> fetch_token_stats()
    |> fetch_by_tag()
  end

  defp fetch_stats(socket) do
    sessions = SessionManager.list_sessions()

    stats = %{
      total: length(sessions),
      active: count_by_state(sessions, [:running, :attached]),
      disconnected: count_by_state(sessions, [:detached]),
      pending: count_by_state(sessions, [:initializing]),
      new_today: count_new_today(sessions),
      active_tokens: 0
    }

    assign(socket, :stats, Map.merge(socket.assigns.stats, stats))
  rescue
    _ -> socket
  end

  defp fetch_token_stats(socket) do
    token_stats = TokenManager.stats()
    stats = Map.put(socket.assigns.stats, :active_tokens, token_stats.active)
    assign(socket, :stats, stats)
  rescue
    _ -> socket
  end

  defp fetch_by_tag(socket) do
    sessions = SessionManager.list_sessions()

    by_tag =
      sessions
      |> Enum.flat_map(fn s -> Map.get(s, :tags, []) end)
      |> Enum.frequencies()

    assign(socket, :by_tag, by_tag)
  rescue
    _ -> socket
  end

  defp count_by_state(sessions, states) do
    Enum.count(sessions, fn s -> s[:state] in states end)
  end

  defp count_new_today(sessions) do
    today = Date.utc_today()

    Enum.count(sessions, fn s ->
      case s[:created_at] do
        nil -> false
        ts when is_integer(ts) ->
          DateTime.from_unix!(div(ts, 1000)) |> DateTime.to_date() == today
        %DateTime{} = dt ->
          DateTime.to_date(dt) == today
        _ -> false
      end
    end)
  end

  defp default_stats do
    %{
      total: 0,
      active: 0,
      disconnected: 0,
      pending: 0,
      new_today: 0,
      active_tokens: 0
    }
  end

  defp trend_text(active, total) when total > 0 do
    percentage = round(active / total * 100)
    "#{percentage}% of total"
  end

  defp trend_text(_, _), do: ""

  defp tag_percentage(_count, 0), do: 0
  defp tag_percentage(count, total), do: round(count / total * 100)

  defp activity_color(:connected), do: "bg-green-500"
  defp activity_color(:disconnected), do: "bg-red-500"
  defp activity_color(:metadata_updated), do: "bg-blue-500"
  defp activity_color(_), do: "bg-gray-500"

  defp activity_text(:connected), do: "connected"
  defp activity_text(:disconnected), do: "disconnected"
  defp activity_text(:metadata_updated), do: "updated metadata"
  defp activity_text(event), do: to_string(event)

  defp format_time_ago(nil), do: "Unknown"

  defp format_time_ago(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "Just now"
      diff < 3600 -> "#{div(diff, 60)} min ago"
      diff < 86400 -> "#{div(diff, 3600)} hours ago"
      true -> Calendar.strftime(datetime, "%b %d, %H:%M")
    end
  end

  # Components

  attr :title, :string, required: true
  attr :value, :integer, required: true
  attr :trend, :string, default: ""
  attr :color, :string, default: "blue"
  attr :icon, :string, default: "chart"

  defp stats_card(assigns) do
    color_classes = %{
      "blue" => "bg-blue-500",
      "green" => "bg-green-500",
      "yellow" => "bg-yellow-500",
      "red" => "bg-red-500",
      "purple" => "bg-purple-500"
    }

    assigns = assign(assigns, :color_class, Map.get(color_classes, assigns.color, "bg-blue-500"))

    ~H"""
    <div class="bg-white dark:bg-gray-800 rounded-lg shadow-md p-6">
      <div class="flex items-center">
        <div class={"flex-shrink-0 p-3 rounded-lg #{@color_class}"}>
          <.icon name={@icon} class="w-6 h-6 text-white" />
        </div>
        <div class="ml-4">
          <p class="text-sm font-medium text-gray-500 dark:text-gray-400"><%= @title %></p>
          <p class="text-2xl font-bold text-gray-900 dark:text-white"><%= @value %></p>
          <%= if @trend != "" do %>
            <p class="text-xs text-gray-500 dark:text-gray-400 mt-1"><%= @trend %></p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :class, :string, default: ""

  defp icon(%{name: "server"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M5 12h14M5 12a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v4a2 2 0 01-2 2M5 12a2 2 0 00-2 2v4a2 2 0 002 2h14a2 2 0 002-2v-4a2 2 0 00-2-2m-2-4h.01M17 16h.01"
      />
    </svg>
    """
  end

  defp icon(%{name: "signal"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M9.663 17h4.673M12 3v1m6.364 1.636l-.707.707M21 12h-1M4 12H3m3.343-5.657l-.707-.707m2.828 9.9a5 5 0 117.072 0l-.548.547A3.374 3.374 0 0014 18.469V19a2 2 0 11-4 0v-.531c0-.895-.356-1.754-.988-2.386l-.548-.547z"
      />
    </svg>
    """
  end

  defp icon(%{name: "offline"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M18.364 5.636a9 9 0 010 12.728m0 0l-2.829-2.829m2.829 2.829L21 21M15.536 8.464a5 5 0 010 7.072m0 0l-2.829-2.829m-4.243 2.829a4.978 4.978 0 01-1.414-2.83m-1.414 5.658a9 9 0 01-2.167-9.238m7.824 2.167a1 1 0 111.414 1.414m-1.414-1.414L3 3m8.293 8.293l1.414 1.414"
      />
    </svg>
    """
  end

  defp icon(%{name: "key"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"
      />
    </svg>
    """
  end

  defp icon(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z"
      />
    </svg>
    """
  end
end
