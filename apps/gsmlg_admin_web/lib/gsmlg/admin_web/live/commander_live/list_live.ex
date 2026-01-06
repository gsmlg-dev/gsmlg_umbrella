defmodule GSMLG.AdminWeb.CommanderLive.ListLive do
  @moduledoc """
  LiveView for listing and filtering commanders.

  Provides a searchable, filterable, and sortable list of all
  connected commander agents with real-time status updates.
  """

  use GSMLG.AdminWeb, :live_view

  alias GSMLG.Commander.SessionManager

  @per_page 25

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GSMLG.PubSub, "commanders:events")
    end

    {:ok,
     socket
     |> assign(:page_title, "Commanders")
     |> assign(:commanders, [])
     |> assign(:page, 1)
     |> assign(:per_page, @per_page)
     |> assign(:total, 0)
     |> assign(:search, "")
     |> assign(:filters, %{status: nil, tags: []})
     |> assign(:sort, {:connected_at, :desc})
     |> assign(:selected, MapSet.new())
     |> fetch_commanders()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    page = String.to_integer(params["page"] || "1")
    search = params["search"] || ""
    status = params["status"]
    tags = parse_tags(params["tags"])

    socket =
      socket
      |> assign(:page, page)
      |> assign(:search, search)
      |> assign(:filters, %{status: status, tags: tags})
      |> fetch_commanders()

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6">
      <div class="mb-6 flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold text-gray-900 dark:text-white">Commanders</h1>
          <p class="mt-1 text-gray-600 dark:text-gray-400">
            <%= @total %> commander(s) connected
          </p>
        </div>
        <.link
          navigate={~p"/commander"}
          class="inline-flex items-center px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-md text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700"
        >
          <svg class="w-5 h-5 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M10 19l-7-7m0 0l7-7m-7 7h18"
            />
          </svg>
          Back to Dashboard
        </.link>
      </div>

      <!-- Search and Filters -->
      <div class="mb-6 bg-white dark:bg-gray-800 rounded-lg shadow-md p-4">
        <div class="flex flex-wrap gap-4">
          <div class="flex-1 min-w-64">
            <form phx-change="search" phx-submit="search">
              <div class="relative">
                <svg
                  class="absolute left-3 top-1/2 -translate-y-1/2 w-5 h-5 text-gray-400"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
                  />
                </svg>
                <input
                  type="text"
                  name="query"
                  value={@search}
                  placeholder="Search commanders..."
                  class="w-full pl-10 pr-4 py-2 border border-gray-300 dark:border-gray-600 rounded-md dark:bg-gray-700 dark:text-white focus:ring-blue-500 focus:border-blue-500"
                  phx-debounce="300"
                />
              </div>
            </form>
          </div>

          <div>
            <select
              phx-change="filter_status"
              name="status"
              class="px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-md dark:bg-gray-700 dark:text-white focus:ring-blue-500 focus:border-blue-500"
            >
              <option value="">All Status</option>
              <option value="running" selected={@filters.status == "running"}>Active</option>
              <option value="attached" selected={@filters.status == "attached"}>Attached</option>
              <option value="detached" selected={@filters.status == "detached"}>Detached</option>
              <option value="initializing" selected={@filters.status == "initializing"}>
                Pending
              </option>
            </select>
          </div>

          <button
            phx-click="refresh"
            class="px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-md text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700"
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

      <!-- Commanders Table -->
      <div class="bg-white dark:bg-gray-800 shadow-md rounded-lg overflow-hidden">
        <table class="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
          <thead class="bg-gray-50 dark:bg-gray-700">
            <tr>
              <th class="w-8 px-4 py-3">
                <input
                  type="checkbox"
                  class="h-4 w-4 text-blue-600 focus:ring-blue-500 border-gray-300 rounded"
                  phx-click="toggle_all"
                  checked={all_selected?(@commanders, @selected)}
                />
              </th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider cursor-pointer hover:bg-gray-100 dark:hover:bg-gray-600"
                  phx-click="sort" phx-value-field="status">
                Status
                <%= if elem(@sort, 0) == :status do %>
                  <span class="ml-1"><%= sort_indicator(elem(@sort, 1)) %></span>
                <% end %>
              </th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider cursor-pointer hover:bg-gray-100 dark:hover:bg-gray-600"
                  phx-click="sort" phx-value-field="hostname">
                Hostname
                <%= if elem(@sort, 0) == :hostname do %>
                  <span class="ml-1"><%= sort_indicator(elem(@sort, 1)) %></span>
                <% end %>
              </th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                Capabilities
              </th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                Tags
              </th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider cursor-pointer hover:bg-gray-100 dark:hover:bg-gray-600"
                  phx-click="sort" phx-value-field="connected_at">
                Connected
                <%= if elem(@sort, 0) == :connected_at do %>
                  <span class="ml-1"><%= sort_indicator(elem(@sort, 1)) %></span>
                <% end %>
              </th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                Actions
              </th>
            </tr>
          </thead>
          <tbody class="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
            <%= for commander <- @commanders do %>
              <tr class="hover:bg-gray-50 dark:hover:bg-gray-700">
                <td class="px-4 py-4">
                  <input
                    type="checkbox"
                    class="h-4 w-4 text-blue-600 focus:ring-blue-500 border-gray-300 rounded"
                    phx-click="toggle_select"
                    phx-value-id={commander.id}
                    checked={MapSet.member?(@selected, commander.id)}
                  />
                </td>
                <td class="px-6 py-4 whitespace-nowrap">
                  <.status_badge status={commander.status} />
                </td>
                <td class="px-6 py-4 whitespace-nowrap">
                  <.link
                    navigate={~p"/commander/#{commander.id}"}
                    class="text-blue-600 dark:text-blue-400 hover:underline font-medium"
                  >
                    <%= commander.hostname %>
                  </.link>
                  <%= if commander.metadata[:ip_address] do %>
                    <span class="text-xs text-gray-500 dark:text-gray-400 block">
                      <%= commander.metadata[:ip_address] %>
                    </span>
                  <% end %>
                </td>
                <td class="px-6 py-4">
                  <div class="flex flex-wrap gap-1">
                    <%= for cap <- commander.capabilities |> Enum.take(4) do %>
                      <.capability_badge capability={cap} />
                    <% end %>
                    <%= if length(commander.capabilities) > 4 do %>
                      <span class="text-xs text-gray-500">
                        +<%= length(commander.capabilities) - 4 %>
                      </span>
                    <% end %>
                  </div>
                </td>
                <td class="px-6 py-4">
                  <div class="flex flex-wrap gap-1">
                    <%= for tag <- commander.tags |> Enum.take(3) do %>
                      <span class="px-2 py-0.5 bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300 text-xs rounded">
                        <%= tag %>
                      </span>
                    <% end %>
                    <%= if length(commander.tags) > 3 do %>
                      <span class="text-xs text-gray-500">
                        +<%= length(commander.tags) - 3 %>
                      </span>
                    <% end %>
                  </div>
                </td>
                <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500 dark:text-gray-400">
                  <%= format_connected_at(commander.connected_at) %>
                </td>
                <td class="px-6 py-4 whitespace-nowrap">
                  <div class="flex space-x-2">
                    <.link
                      navigate={~p"/commander/#{commander.id}"}
                      class="text-blue-600 hover:text-blue-800 dark:text-blue-400 dark:hover:text-blue-300 text-sm"
                    >
                      View
                    </.link>
                    <%= if :shell in commander.capabilities do %>
                      <.link
                        navigate={~p"/commander/#{commander.id}/shell"}
                        class="text-green-600 hover:text-green-800 dark:text-green-400 dark:hover:text-green-300 text-sm"
                      >
                        Shell
                      </.link>
                    <% end %>
                  </div>
                </td>
              </tr>
            <% end %>
            <%= if Enum.empty?(@commanders) do %>
              <tr>
                <td colspan="7" class="px-6 py-12 text-center text-gray-500 dark:text-gray-400">
                  <%= if @search != "" || @filters.status do %>
                    No commanders found matching your filters.
                  <% else %>
                    No commanders connected. Generate a token and configure an agent to get started.
                  <% end %>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>

        <!-- Pagination -->
        <%= if @total > @per_page do %>
          <div class="px-6 py-4 border-t border-gray-200 dark:border-gray-700 flex items-center justify-between">
            <div class="text-sm text-gray-500 dark:text-gray-400">
              Showing <%= (@page - 1) * @per_page + 1 %> to <%= min(@page * @per_page, @total) %> of <%= @total %> commanders
            </div>
            <div class="flex space-x-2">
              <%= if @page > 1 do %>
                <.link
                  patch={build_url(@search, @filters, @page - 1)}
                  class="px-3 py-1 border border-gray-300 dark:border-gray-600 rounded-md text-sm hover:bg-gray-50 dark:hover:bg-gray-700"
                >
                  Previous
                </.link>
              <% end %>
              <%= if @page * @per_page < @total do %>
                <.link
                  patch={build_url(@search, @filters, @page + 1)}
                  class="px-3 py-1 border border-gray-300 dark:border-gray-600 rounded-md text-sm hover:bg-gray-50 dark:hover:bg-gray-700"
                >
                  Next
                </.link>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>

      <!-- Bulk Actions -->
      <%= if MapSet.size(@selected) > 0 do %>
        <div class="fixed bottom-6 left-1/2 -translate-x-1/2 bg-gray-900 text-white px-6 py-3 rounded-lg shadow-lg flex items-center space-x-4">
          <span><%= MapSet.size(@selected) %> selected</span>
          <button
            phx-click="clear_selection"
            class="text-gray-400 hover:text-white text-sm"
          >
            Clear
          </button>
          <button class="px-3 py-1 bg-red-600 rounded hover:bg-red-700 text-sm">
            Disconnect Selected
          </button>
        </div>
      <% end %>
    </div>
    """
  end

  # Event Handlers

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, push_patch(socket, to: build_url(query, socket.assigns.filters, 1))}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    filters = %{socket.assigns.filters | status: if(status == "", do: nil, else: status)}
    {:noreply, push_patch(socket, to: build_url(socket.assigns.search, filters, 1))}
  end

  @impl true
  def handle_event("sort", %{"field" => field}, socket) do
    field_atom = String.to_existing_atom(field)
    {current_field, current_dir} = socket.assigns.sort

    new_dir =
      if current_field == field_atom do
        if current_dir == :asc, do: :desc, else: :asc
      else
        :desc
      end

    socket =
      socket
      |> assign(:sort, {field_atom, new_dir})
      |> fetch_commanders()

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_select", %{"id" => id}, socket) do
    selected =
      if MapSet.member?(socket.assigns.selected, id) do
        MapSet.delete(socket.assigns.selected, id)
      else
        MapSet.put(socket.assigns.selected, id)
      end

    {:noreply, assign(socket, :selected, selected)}
  end

  @impl true
  def handle_event("toggle_all", _params, socket) do
    selected =
      if all_selected?(socket.assigns.commanders, socket.assigns.selected) do
        MapSet.new()
      else
        socket.assigns.commanders
        |> Enum.map(& &1.id)
        |> MapSet.new()
      end

    {:noreply, assign(socket, :selected, selected)}
  end

  @impl true
  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected, MapSet.new())}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, fetch_commanders(socket)}
  end

  @impl true
  def handle_info({:commander_event, _event}, socket) do
    {:noreply, fetch_commanders(socket)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Private Functions

  defp fetch_commanders(socket) do
    sessions = SessionManager.list_sessions()

    commanders =
      sessions
      |> Enum.map(&format_commander/1)
      |> filter_commanders(socket.assigns.search, socket.assigns.filters)
      |> sort_commanders(socket.assigns.sort)

    total = length(commanders)
    page = socket.assigns.page
    per_page = socket.assigns.per_page

    paginated =
      commanders
      |> Enum.drop((page - 1) * per_page)
      |> Enum.take(per_page)

    socket
    |> assign(:commanders, paginated)
    |> assign(:total, total)
  rescue
    _ ->
      socket
      |> assign(:commanders, [])
      |> assign(:total, 0)
  end

  defp format_commander(session) do
    %{
      id: session[:session_id],
      hostname: session[:hostname] || session[:session_id],
      status: session[:state],
      capabilities: Map.get(session, :capabilities, []),
      tags: Map.get(session, :tags, []),
      connected_at: session[:created_at],
      last_activity: session[:last_activity],
      metadata: Map.get(session, :metadata, %{})
    }
  end

  defp filter_commanders(commanders, search, filters) do
    commanders
    |> maybe_filter_search(search)
    |> maybe_filter_status(filters.status)
    |> maybe_filter_tags(filters.tags)
  end

  defp maybe_filter_search(commanders, nil), do: commanders
  defp maybe_filter_search(commanders, ""), do: commanders

  defp maybe_filter_search(commanders, search) do
    search_lower = String.downcase(search)

    Enum.filter(commanders, fn c ->
      String.contains?(String.downcase(c.hostname || ""), search_lower)
    end)
  end

  defp maybe_filter_status(commanders, nil), do: commanders

  defp maybe_filter_status(commanders, status) do
    status_atom = String.to_existing_atom(status)
    Enum.filter(commanders, &(&1.status == status_atom))
  rescue
    _ -> commanders
  end

  defp maybe_filter_tags(commanders, nil), do: commanders
  defp maybe_filter_tags(commanders, []), do: commanders

  defp maybe_filter_tags(commanders, tags) do
    Enum.filter(commanders, fn c ->
      Enum.any?(tags, &(&1 in c.tags))
    end)
  end

  defp sort_commanders(commanders, {field, direction}) do
    sorted = Enum.sort_by(commanders, &Map.get(&1, field))
    if direction == :desc, do: Enum.reverse(sorted), else: sorted
  end

  defp parse_tags(nil), do: []
  defp parse_tags(""), do: []

  defp parse_tags(tags) when is_binary(tags) do
    tags |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp parse_tags(tags) when is_list(tags), do: tags

  defp build_url(search, filters, page) do
    params = []
    params = if search != "", do: [{"search", search} | params], else: params
    params = if filters.status, do: [{"status", filters.status} | params], else: params
    params = if filters.tags != [], do: [{"tags", Enum.join(filters.tags, ",")} | params], else: params
    params = if page > 1, do: [{"page", to_string(page)} | params], else: params

    if params == [] do
      ~p"/commander/list"
    else
      ~p"/commander/list?#{params}"
    end
  end

  defp all_selected?(commanders, selected) do
    length(commanders) > 0 &&
      Enum.all?(commanders, fn c -> MapSet.member?(selected, c.id) end)
  end

  defp sort_indicator(:asc), do: "^"
  defp sort_indicator(:desc), do: "v"

  defp format_connected_at(nil), do: "-"

  defp format_connected_at(ts) when is_integer(ts) do
    DateTime.from_unix!(div(ts, 1000))
    |> format_time_ago()
  end

  defp format_connected_at(%DateTime{} = dt), do: format_time_ago(dt)
  defp format_connected_at(_), do: "-"

  defp format_time_ago(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "Just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86400)}d ago"
      true -> Calendar.strftime(datetime, "%b %d")
    end
  end

  # Components

  defp status_badge(assigns) do
    {bg_color, text_color, label} =
      case assigns.status do
        :running -> {"bg-green-100 dark:bg-green-900", "text-green-800 dark:text-green-200", "Active"}
        :attached -> {"bg-green-100 dark:bg-green-900", "text-green-800 dark:text-green-200", "Attached"}
        :detached -> {"bg-yellow-100 dark:bg-yellow-900", "text-yellow-800 dark:text-yellow-200", "Detached"}
        :initializing -> {"bg-blue-100 dark:bg-blue-900", "text-blue-800 dark:text-blue-200", "Pending"}
        :closing -> {"bg-red-100 dark:bg-red-900", "text-red-800 dark:text-red-200", "Closing"}
        _ -> {"bg-gray-100 dark:bg-gray-700", "text-gray-800 dark:text-gray-200", to_string(assigns.status)}
      end

    assigns = assign(assigns, bg_color: bg_color, text_color: text_color, label: label)

    ~H"""
    <span class={"inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium #{@bg_color} #{@text_color}"}>
      <%= @label %>
    </span>
    """
  end

  defp capability_badge(assigns) do
    {icon, title} =
      case assigns.capability do
        :shell -> {"terminal", "Shell"}
        :files -> {"folder", "Files"}
        :processes -> {"cpu", "Processes"}
        :system_info -> {"info", "System Info"}
        :logs -> {"document", "Logs"}
        :metrics -> {"chart", "Metrics"}
        :services -> {"cog", "Services"}
        _ -> {"question", to_string(assigns.capability)}
      end

    assigns = assign(assigns, icon: icon, title: title)

    ~H"""
    <span
      class="inline-flex items-center justify-center w-6 h-6 bg-blue-100 dark:bg-blue-900 rounded"
      title={@title}
    >
      <.cap_icon name={@icon} />
    </span>
    """
  end

  defp cap_icon(%{name: "terminal"} = assigns) do
    ~H"""
    <svg class="w-3.5 h-3.5 text-blue-600 dark:text-blue-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 9l3 3-3 3m5 0h3M5 20h14a2 2 0 002-2V6a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z" />
    </svg>
    """
  end

  defp cap_icon(%{name: "folder"} = assigns) do
    ~H"""
    <svg class="w-3.5 h-3.5 text-blue-600 dark:text-blue-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z" />
    </svg>
    """
  end

  defp cap_icon(%{name: "cpu"} = assigns) do
    ~H"""
    <svg class="w-3.5 h-3.5 text-blue-600 dark:text-blue-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 3v2m6-2v2M9 19v2m6-2v2M5 9H3m2 6H3m18-6h-2m2 6h-2M7 19h10a2 2 0 002-2V7a2 2 0 00-2-2H7a2 2 0 00-2 2v10a2 2 0 002 2zM9 9h6v6H9V9z" />
    </svg>
    """
  end

  defp cap_icon(%{name: "info"} = assigns) do
    ~H"""
    <svg class="w-3.5 h-3.5 text-blue-600 dark:text-blue-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
    </svg>
    """
  end

  defp cap_icon(assigns) do
    ~H"""
    <svg class="w-3.5 h-3.5 text-blue-600 dark:text-blue-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8.228 9c.549-1.165 2.03-2 3.772-2 2.21 0 4 1.343 4 3 0 1.4-1.278 2.575-3.006 2.907-.542.104-.994.54-.994 1.093m0 3h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
    </svg>
    """
  end
end
