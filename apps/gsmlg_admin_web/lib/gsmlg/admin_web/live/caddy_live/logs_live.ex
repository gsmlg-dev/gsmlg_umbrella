defmodule GSMLG.AdminWeb.CaddyLive.LogsLive do
  @moduledoc """
  Caddy log viewer — discovers log files from the Caddy runtime config and
  lets the user select a source to view with partial file streaming.
  """
  use GSMLG.AdminWeb, :live_view

  alias GSMLG.AdminWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    log_sources = fetch_log_sources()

    socket =
      socket
      |> assign(:page_title, "Caddy Logs")
      |> assign(:active_menu, "caddy_logs")
      |> assign(:log_sources, log_sources)
      |> assign(:selected_source, nil)
      |> assign(:log_lines, [])
      |> assign(:filtered_lines, [])
      |> assign(:tail_lines, 200)
      |> assign(:search_query, "")
      |> assign(:auto_refresh, false)
      |> assign(:refresh_timer, nil)
      |> assign(:error, nil)
      |> assign(:file_size, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("select_source", %{"source" => source_id}, socket) do
    source = Enum.find(socket.assigns.log_sources, &(&1.id == source_id))

    socket =
      socket
      |> cancel_refresh_timer()
      |> assign(:selected_source, source)
      |> assign(:search_query, "")
      |> load_log_content()

    socket = if socket.assigns.auto_refresh, do: schedule_refresh(socket), else: socket

    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh_sources", _params, socket) do
    log_sources = fetch_log_sources()
    {:noreply, assign(socket, :log_sources, log_sources)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_log_content(socket)}
  end

  @impl true
  def handle_event("update_tail_lines", %{"tail_lines" => tail_lines}, socket) do
    case Integer.parse(tail_lines) do
      {lines, _} when lines > 0 ->
        {:noreply, socket |> assign(:tail_lines, lines) |> load_log_content()}

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

    socket = if auto_refresh and socket.assigns.selected_source, do: schedule_refresh(socket), else: socket

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    {:noreply, socket |> assign(:search_query, query) |> filter_lines()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, socket |> load_log_content() |> schedule_refresh()}
  end

  # ── Log source discovery ──────────────────────────────────────────────────

  defp fetch_log_sources do
    file_sources = fetch_file_sources_from_runtime()
    buffer_source = process_buffer_source()

    [buffer_source | file_sources]
  end

  # Always expose the in-process buffer (stdout/stderr from embedded Caddy)
  defp process_buffer_source do
    %{id: "__process_buffer__", name: "Process Buffer", type: :buffer, path: nil}
  end

  defp fetch_file_sources_from_runtime do
    try do
      case Caddy.get_runtime_config("logging") do
        {:ok, %{"logs" => logs}} when is_map(logs) ->
          logs
          |> Enum.flat_map(fn {log_name, log_config} ->
            extract_file_source(log_name, log_config)
          end)

        _ ->
          []
      end
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp extract_file_source(log_name, %{"writer" => %{"output" => "file", "filename" => path}})
       when is_binary(path) do
    [%{id: "file:#{log_name}", name: log_name, type: :file, path: path}]
  end

  defp extract_file_source(_log_name, _log_config), do: []

  # ── Log content loading ───────────────────────────────────────────────────

  defp load_log_content(%{assigns: %{selected_source: nil}} = socket) do
    socket |> assign(:log_lines, []) |> assign(:filtered_lines, []) |> assign(:file_size, nil)
  end

  defp load_log_content(%{assigns: %{selected_source: %{type: :buffer}}} = socket) do
    {lines, error} =
      try do
        lines = Caddy.Logger.tail(socket.assigns.tail_lines)
        {lines, nil}
      rescue
        e -> {[], Exception.message(e)}
      catch
        :exit, _ -> {[], "Caddy Logger process unavailable"}
      end

    socket
    |> assign(:log_lines, lines)
    |> assign(:error, error)
    |> assign(:file_size, nil)
    |> filter_lines()
  end

  defp load_log_content(%{assigns: %{selected_source: %{type: :file, path: path}}} = socket) do
    {lines, file_size, error} = read_file_tail(path, socket.assigns.tail_lines)

    socket
    |> assign(:log_lines, lines)
    |> assign(:file_size, file_size)
    |> assign(:error, error)
    |> filter_lines()
  end

  defp read_file_tail(path, num_lines) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} ->
        lines =
          try do
            path
            |> File.stream!(:line)
            |> Enum.to_list()
            |> Enum.take(-num_lines)
            |> Enum.map(&String.trim_trailing(&1, "\n"))
          rescue
            e -> {:error, Exception.message(e)}
          end

        case lines do
          {:error, msg} -> {[], size, msg}
          lines -> {lines, size, nil}
        end

      {:error, reason} ->
        {[], nil, "Cannot stat #{path}: #{:file.format_error(reason)}"}
    end
  end

  # ── Filtering ─────────────────────────────────────────────────────────────

  defp filter_lines(socket) do
    %{log_lines: lines, search_query: query} = socket.assigns

    filtered =
      if query == "" do
        lines
      else
        query_lower = String.downcase(query)
        Enum.filter(lines, &(String.downcase(&1) |> String.contains?(query_lower)))
      end

    assign(socket, :filtered_lines, Enum.reverse(filtered))
  end

  # ── Auto-refresh ──────────────────────────────────────────────────────────

  defp schedule_refresh(socket) do
    if socket.assigns.auto_refresh do
      timer = Process.send_after(self(), :refresh, 5_000)
      assign(socket, :refresh_timer, timer)
    else
      socket
    end
  end

  defp cancel_refresh_timer(socket) do
    if socket.assigns.refresh_timer, do: Process.cancel_timer(socket.assigns.refresh_timer)
    assign(socket, :refresh_timer, nil)
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp format_bytes(nil), do: "unknown"

  defp format_bytes(bytes) when bytes < 1_024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1_024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  # ── Render ────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.caddy flash={@flash} page_title={@page_title} active_menu={@active_menu}>
      <div class="p-6 space-y-6">
        <div class="flex items-center justify-between">
          <h1 class="text-3xl font-bold">Logs</h1>
          <div class="flex gap-2 items-center">
            <div :if={@selected_source} class="badge badge-lg badge-primary">
              {length(@filtered_lines)} / {length(@log_lines)} lines
            </div>
            <button phx-click="refresh_sources" class="btn btn-ghost btn-sm">
              <.dm_mdi name="refresh" class="size-4" /> Discover
            </button>
          </div>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-4 gap-6">
          <%!-- Left: Source list --%>
          <div class="lg:col-span-1">
            <div class="card bg-base-100 shadow">
              <div class="card-body p-4">
                <h2 class="card-title text-sm">
                  <.dm_mdi name="file-multiple-outline" class="size-4" /> Log Sources
                </h2>

                <div :if={@log_sources == []} class="text-sm text-base-content/50 py-2">
                  No sources found
                </div>

                <ul class="menu menu-sm p-0 gap-1">
                  <%= for source <- @log_sources do %>
                    <li>
                      <button
                        phx-click="select_source"
                        phx-value-source={source.id}
                        class={[
                          "flex flex-col items-start gap-0.5 text-left",
                          @selected_source && @selected_source.id == source.id && "active"
                        ]}
                      >
                        <span class="font-medium text-sm truncate w-full">{source.name}</span>
                        <span class={[
                          "badge badge-xs",
                          source.type == :buffer && "badge-info",
                          source.type == :file && "badge-ghost"
                        ]}>
                          {source.type}
                        </span>
                        <span :if={source.path} class="font-mono text-xs text-base-content/40 truncate w-full">
                          {source.path}
                        </span>
                      </button>
                    </li>
                  <% end %>
                </ul>
              </div>
            </div>
          </div>

          <%!-- Right: Controls + viewer --%>
          <div class="lg:col-span-3 space-y-4">
            <%!-- No source selected --%>
            <div :if={is_nil(@selected_source)} class="card bg-base-100 shadow">
              <div class="card-body text-center py-16 text-base-content/50">
                <.dm_mdi name="file-search-outline" class="size-12 mx-auto mb-4 opacity-50" />
                <p class="text-lg font-semibold">Select a log source</p>
                <p class="text-sm mt-2">
                  Choose a source from the left to view its log output.
                  File sources are discovered from the Caddy runtime configuration.
                </p>
              </div>
            </div>

            <div :if={@selected_source} class="space-y-4">
              <%!-- Controls --%>
              <div class="card bg-base-100 shadow">
                <div class="card-body p-4">
                  <div class="flex items-center justify-between mb-3">
                    <h2 class="card-title text-sm">
                      <.dm_mdi name="tune-vertical" class="size-4" /> Controls
                    </h2>
                    <div :if={@selected_source.type == :file and @file_size} class="text-xs text-base-content/50">
                      File size: {format_bytes(@file_size)}
                      &nbsp;· Path: <span class="font-mono">{@selected_source.path}</span>
                    </div>
                  </div>
                  <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <div class="space-y-3">
                      <div class="form-control">
                        <label class="label py-1"><span class="label-text text-xs">Tail Lines</span></label>
                        <div class="join">
                          <input
                            type="number"
                            name="tail_lines"
                            value={@tail_lines}
                            min="1"
                            max="10000"
                            class="input input-bordered input-sm join-item flex-1"
                            phx-change="update_tail_lines"
                          />
                          <button class="btn btn-primary btn-sm join-item" phx-click="refresh">
                            <.dm_mdi name="refresh" class="size-4" />
                          </button>
                        </div>
                      </div>
                      <div class="form-control">
                        <label class="label cursor-pointer py-1">
                          <span class="label-text text-xs">Auto-refresh (5s)</span>
                          <input
                            type="checkbox"
                            class="toggle toggle-primary toggle-sm"
                            checked={@auto_refresh}
                            phx-change="toggle_auto_refresh"
                          />
                        </label>
                      </div>
                    </div>
                    <div class="form-control">
                      <label class="label py-1"><span class="label-text text-xs">Search</span></label>
                      <form phx-change="search">
                        <input
                          type="text"
                          name="search[query]"
                          value={@search_query}
                          placeholder="Filter lines..."
                          class="input input-bordered input-sm w-full"
                        />
                      </form>
                      <label :if={@search_query != ""} class="label py-1">
                        <span class="label-text-alt">
                          {length(@filtered_lines)} / {length(@log_lines)} lines match
                        </span>
                      </label>
                    </div>
                  </div>
                </div>
              </div>

              <%!-- Error --%>
              <div :if={@error} class="alert alert-warning">
                <.dm_mdi name="alert-outline" class="size-5" />
                <span>{@error}</span>
              </div>

              <%!-- Log output --%>
              <div class="card bg-base-100 shadow">
                <div class="card-body p-4">
                  <h2 class="card-title text-sm">
                    <.dm_mdi name="text-box-outline" class="size-4" />
                    Log Output — <span class="font-normal text-base-content/60">{@selected_source.name}</span>
                  </h2>

                  <div :if={Enum.empty?(@filtered_lines)} class="text-center py-10 text-base-content/50">
                    <.dm_mdi name="file-search-outline" class="size-10 mx-auto mb-3 opacity-50" />
                    <p class="text-sm font-semibold">
                      {if @search_query != "", do: "No matching lines", else: "No log output"}
                    </p>
                    <p :if={@search_query != ""} class="text-xs mt-1">Adjust your search query</p>
                  </div>

                  <div :if={!Enum.empty?(@filtered_lines)}
                       class="bg-base-200 rounded-lg p-4 overflow-auto"
                       style="max-height: 600px;">
                    <pre class="font-mono text-xs whitespace-pre-wrap break-words leading-relaxed"><code>{Enum.join(@filtered_lines, "\n")}</code></pre>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.caddy>
    """
  end
end
