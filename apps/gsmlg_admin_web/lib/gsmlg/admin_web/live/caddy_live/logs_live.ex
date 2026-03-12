defmodule GSMLG.AdminWeb.CaddyLive.LogsLive do
  @moduledoc """
  Caddy log viewer with tail control, search filtering, and optional auto-refresh.
  """
  use GSMLG.AdminWeb, :live_view

  alias GSMLG.AdminWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Caddy Logs")
      |> assign(:active_menu, "caddy_logs")
      |> assign(:logs, [])
      |> assign(:filtered_logs, [])
      |> assign(:tail_lines, 100)
      |> assign(:search_query, "")
      |> assign(:auto_refresh, false)
      |> assign(:refresh_timer, nil)
      |> assign(:error, nil)
      |> load_logs()

    {:ok, socket}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_logs(socket)}
  end

  @impl true
  def handle_event("update_tail_lines", %{"tail_lines" => tail_lines}, socket) do
    case Integer.parse(tail_lines) do
      {lines, _} when lines > 0 ->
        {:noreply, socket |> assign(:tail_lines, lines) |> load_logs()}

      _ ->
        {:noreply, put_flash(socket, :error, "Please enter a valid positive number")}
    end
  end

  @impl true
  def handle_event("toggle_auto_refresh", %{"value" => value}, socket) do
    auto_refresh = value == "on"

    socket =
      socket
      |> cancel_refresh_timer()
      |> assign(:auto_refresh, auto_refresh)

    socket = if auto_refresh, do: schedule_refresh(socket), else: socket
    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    {:noreply, socket |> assign(:search_query, query) |> filter_logs()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, socket |> load_logs() |> schedule_refresh()}
  end

  defp load_logs(socket) do
    {logs, error} =
      try do
        case Caddy.Logger.tail(socket.assigns.tail_lines) do
          logs when is_list(logs) -> {logs, nil}
          _ -> {[], "Invalid response from Logger"}
        end
      rescue
        e -> {[], Exception.message(e)}
      end

    socket
    |> assign(:logs, logs)
    |> assign(:error, error)
    |> filter_logs()
  end

  defp filter_logs(socket) do
    %{logs: logs, search_query: query} = socket.assigns

    filtered_logs =
      if query == "" do
        logs
      else
        query_lower = String.downcase(query)

        Enum.filter(logs, fn log ->
          log |> to_string() |> String.downcase() |> String.contains?(query_lower)
        end)
      end

    assign(socket, :filtered_logs, filtered_logs)
  end

  defp schedule_refresh(socket) do
    if socket.assigns.auto_refresh do
      timer = Process.send_after(self(), :refresh, 5_000)
      assign(socket, :refresh_timer, timer)
    else
      socket
    end
  end

  defp cancel_refresh_timer(socket) do
    if socket.assigns.refresh_timer do
      Process.cancel_timer(socket.assigns.refresh_timer)
    end

    assign(socket, :refresh_timer, nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.caddy flash={@flash} page_title={@page_title} active_menu={@active_menu}>
      <div class="p-6 space-y-6">
        <div class="flex items-center justify-between">
          <h1 class="text-3xl font-bold">Logs</h1>
          <div class="badge badge-lg badge-primary">
            {length(@logs)} total / {length(@filtered_logs)} displayed
          </div>
        </div>

        <div :if={@error} class="alert alert-warning">
          <.dm_mdi name="alert-outline" class="size-5" />
          <span>Logger unavailable: {@error}</span>
        </div>

        <div class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title">Controls</h2>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div class="space-y-4">
                <div class="form-control">
                  <label class="label"><span class="label-text">Tail Lines</span></label>
                  <div class="join">
                    <input
                      type="number"
                      name="tail_lines"
                      value={@tail_lines}
                      min="1"
                      max="10000"
                      class="input input-bordered join-item flex-1"
                      phx-change="update_tail_lines"
                    />
                    <button class="btn btn-primary join-item" phx-click="refresh">Refresh</button>
                  </div>
                </div>
                <div class="form-control">
                  <label class="label cursor-pointer">
                    <span class="label-text">Auto-refresh (every 5s)</span>
                    <input
                      type="checkbox"
                      class="toggle toggle-primary"
                      checked={@auto_refresh}
                      phx-change="toggle_auto_refresh"
                    />
                  </label>
                </div>
              </div>
              <div class="space-y-4">
                <div class="form-control">
                  <label class="label"><span class="label-text">Search Logs</span></label>
                  <form phx-change="search">
                    <input
                      type="text"
                      name="search[query]"
                      value={@search_query}
                      placeholder="Filter by text..."
                      class="input input-bordered w-full"
                    />
                  </form>
                  <label :if={@search_query != ""} class="label">
                    <span class="label-text-alt">
                      Showing {length(@filtered_logs)} of {length(@logs)} logs
                    </span>
                  </label>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title">Log Output</h2>
            <div :if={Enum.empty?(@filtered_logs)} class="text-center py-12 text-base-content/50">
              <.dm_mdi name="file-search-outline" class="size-12 mx-auto mb-4 opacity-50" />
              <%= if @error do %>
                <p class="text-lg font-semibold">No logs available</p>
                <p class="text-sm mt-2">The Logger process may not be running</p>
              <% else %>
                <p class="text-lg font-semibold">{if @search_query != "", do: "No matching logs found", else: "No logs available"}</p>
                <p :if={@search_query != ""} class="text-sm mt-2">Try adjusting your search query</p>
              <% end %>
            </div>
            <div :if={!Enum.empty?(@filtered_logs)} class="bg-base-200 rounded-lg p-4 overflow-auto" style="max-height: 600px;">
              <pre class="font-mono text-sm whitespace-pre-wrap break-words"><code>{Enum.join(@filtered_logs, "\n")}</code></pre>
            </div>
          </div>
        </div>
      </div>
    </Layouts.caddy>
    """
  end
end
