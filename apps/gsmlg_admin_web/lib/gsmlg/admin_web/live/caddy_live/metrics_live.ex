defmodule GSMLG.AdminWeb.CaddyLive.MetricsLive do
  @moduledoc """
  Caddy Prometheus metrics viewer with auto-refresh every 15 seconds.
  """
  use GSMLG.AdminWeb, :live_view

  alias GSMLG.AdminWeb.Layouts

  @refresh_interval 15_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_refresh()

    socket =
      socket
      |> assign(:page_title, "Caddy Metrics")
      |> assign(:active_menu, "caddy_metrics")
      |> assign(:show_raw, false)
      |> assign(:raw_metrics, nil)
      |> assign(:refresh_interval, @refresh_interval)
      |> fetch_metrics()

    {:ok, socket}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, fetch_metrics(socket)}
  end

  @impl true
  def handle_event("toggle_raw", _params, socket) do
    socket =
      if socket.assigns.show_raw do
        assign(socket, :show_raw, false)
      else
        socket |> assign(:show_raw, true) |> fetch_raw_metrics()
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:refresh_metrics, socket) do
    schedule_refresh()
    {:noreply, fetch_metrics(socket)}
  end

  defp fetch_metrics(socket) do
    try do
      case Caddy.Metrics.fetch() do
        {:ok, metrics} ->
          socket |> assign(:metrics, metrics) |> assign(:metrics_error, nil)

        {:error, reason} ->
          socket |> assign(:metrics, nil) |> assign(:metrics_error, format_error(reason))
      end
    rescue
      error ->
        socket
        |> assign(:metrics, nil)
        |> assign(:metrics_error, "Failed to fetch metrics: #{Exception.message(error)}")
    catch
      :exit, _ ->
        socket |> assign(:metrics, nil) |> assign(:metrics_error, "Caddy service unavailable")
    end
  end

  defp fetch_raw_metrics(socket) do
    try do
      case Caddy.Metrics.fetch_raw() do
        {:ok, raw_text} -> assign(socket, :raw_metrics, raw_text)
        {:error, _} -> assign(socket, :raw_metrics, "Failed to fetch raw metrics")
      end
    rescue
      error -> assign(socket, :raw_metrics, "Error: #{Exception.message(error)}")
    catch
      :exit, _ -> assign(socket, :raw_metrics, "Caddy service unavailable")
    end
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh_metrics, @refresh_interval)
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)

  defp format_percentage(value) when is_number(value) do
    :erlang.float_to_binary(value * 100, decimals: 2) <> "%"
  end

  defp format_percentage(_), do: "N/A"

  defp format_duration(ms) when is_number(ms) and ms < 1 do
    :erlang.float_to_binary(ms * 1000, decimals: 0) <> "μs"
  end

  defp format_duration(ms) when is_number(ms) and ms < 1000 do
    :erlang.float_to_binary(ms, decimals: 2) <> "ms"
  end

  defp format_duration(ms) when is_number(ms) do
    :erlang.float_to_binary(ms / 1000, decimals: 2) <> "s"
  end

  defp format_duration(_), do: "N/A"

  defp format_number(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_number(value) when is_float(value) do
    :erlang.float_to_binary(value, decimals: 2)
  end

  defp format_number(_), do: "N/A"

  defp format_bytes(bytes) when is_number(bytes) and bytes < 1024, do: "#{format_number(bytes)} B"

  defp format_bytes(bytes) when is_number(bytes) and bytes < 1024 * 1024 do
    "#{format_number(Float.round(bytes / 1024, 2))} KB"
  end

  defp format_bytes(bytes) when is_number(bytes) and bytes < 1024 * 1024 * 1024 do
    "#{format_number(Float.round(bytes / 1024 / 1024, 2))} MB"
  end

  defp format_bytes(bytes) when is_number(bytes) do
    "#{format_number(Float.round(bytes / 1024 / 1024 / 1024, 2))} GB"
  end

  defp format_bytes(_), do: "N/A"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} active_menu={@active_menu}>
      <div class="p-6 space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-3xl font-bold">Metrics</h1>
            <p class="text-base-content/60 mt-1">
              Caddy Prometheus metrics and performance statistics
            </p>
          </div>
          <div class="flex gap-2">
            <button phx-click="refresh" class="btn btn-primary btn-sm gap-2">
              <.dm_mdi name="refresh" class="size-4" /> Refresh
            </button>
            <button phx-click="toggle_raw" class={["btn btn-sm", @show_raw && "btn-active"]}>
              <.dm_mdi name="code-brackets" class="size-4" />
              {if @show_raw, do: "Hide Raw", else: "Show Raw"}
            </button>
          </div>
        </div>

        <div :if={@metrics_error} class="alert alert-warning">
          <.dm_mdi name="alert-outline" class="size-5" />
          <div>
            <h3 class="font-bold">Metrics Unavailable</h3>
            <div class="text-sm">{@metrics_error}</div>
            <div class="text-xs mt-2 opacity-75">
              Make sure Caddy is running and metrics are enabled.
            </div>
          </div>
        </div>

        <div :if={!@metrics_error && @metrics}>
          <div class="stats stats-vertical lg:stats-horizontal shadow w-full bg-base-100">
            <div class="stat">
              <div class="stat-title">Health Status</div>
              <div class="stat-value">
                <div class={[
                  "badge badge-lg",
                  Caddy.Metrics.healthy?(@metrics) && "badge-success",
                  !Caddy.Metrics.healthy?(@metrics) && "badge-error"
                ]}>
                  {if Caddy.Metrics.healthy?(@metrics), do: "Healthy", else: "Unhealthy"}
                </div>
              </div>
              <div class="stat-desc">System operational status</div>
            </div>
            <div class="stat">
              <div class="stat-title">Error Rate</div>
              <div class="stat-value text-2xl">
                {format_percentage(Caddy.Metrics.error_rate(@metrics))}
              </div>
              <div class="stat-desc">Failed requests</div>
            </div>
            <div class="stat">
              <div class="stat-title">P50 Latency</div>
              <div class="stat-value text-2xl">
                {format_duration(Caddy.Metrics.latency_p50(@metrics))}
              </div>
              <div class="stat-desc">Median response time</div>
            </div>
            <div class="stat">
              <div class="stat-title">P99 Latency</div>
              <div class="stat-value text-2xl">
                {format_duration(Caddy.Metrics.latency_p99(@metrics))}
              </div>
              <div class="stat-desc">99th percentile</div>
            </div>
            <div class="stat">
              <div class="stat-title">Total Requests</div>
              <div class="stat-value text-2xl">
                {format_number(Caddy.Metrics.total_requests(@metrics))}
              </div>
              <div class="stat-desc">Lifetime count</div>
            </div>
          </div>

          <div class="card bg-base-100 shadow mt-6">
            <div class="card-body">
              <h2 class="card-title">
                <.dm_mdi name="chip" class="size-5" /> Process Metrics
              </h2>
              <div class="stats stats-vertical lg:stats-horizontal shadow-sm">
                <div class="stat">
                  <div class="stat-title">CPU Seconds</div>
                  <div class="stat-value text-2xl">
                    {format_number(@metrics.process_cpu_seconds_total)}
                  </div>
                </div>
                <div class="stat">
                  <div class="stat-title">Memory Usage</div>
                  <div class="stat-value text-2xl">
                    {format_bytes(@metrics.process_resident_memory_bytes)}
                  </div>
                </div>
                <div class="stat">
                  <div class="stat-title">Open FDs</div>
                  <div class="stat-value text-2xl">{format_number(@metrics.process_open_fds)}</div>
                </div>
              </div>
            </div>
          </div>

          <div
            :if={map_size(@metrics.reverse_proxy_upstreams_healthy) > 0}
            class="card bg-base-100 shadow mt-6"
          >
            <div class="card-body">
              <h2 class="card-title">
                <.dm_mdi name="server" class="size-5" /> Upstream Health
              </h2>
              <div class="overflow-x-auto">
                <table class="table table-zebra">
                  <thead>
                    <tr>
                      <th>Upstream</th>
                      <th>Status</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for {labels, value} <- @metrics.reverse_proxy_upstreams_healthy do %>
                      <tr>
                        <td><code class="text-sm">{Map.get(labels, :upstream, "unknown")}</code></td>
                        <td>
                          <div class={[
                            "badge",
                            value == 1 && "badge-success",
                            value == 0 && "badge-error"
                          ]}>
                            {if value == 1, do: "Healthy", else: "Unhealthy"}
                          </div>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </div>
          </div>

          <div :if={@show_raw} class="card bg-base-100 shadow mt-6">
            <div class="card-body">
              <h2 class="card-title">
                <.dm_mdi name="text-box-outline" class="size-5" /> Raw Prometheus Metrics
              </h2>
              <div :if={@raw_metrics}>
                <pre class="bg-base-200 p-4 rounded-lg overflow-x-auto text-xs"><code>{@raw_metrics}</code></pre>
              </div>
              <div :if={!@raw_metrics} class="alert alert-info">
                <.dm_mdi name="information-outline" class="size-5" /> <span>Loading...</span>
              </div>
            </div>
          </div>
        </div>

        <div class="text-xs text-base-content/50 text-center">
          <.dm_mdi name="refresh" class="size-3 inline" />
          Auto-refreshing every {div(@refresh_interval, 1000)} seconds
        </div>
      </div>
    </Layouts.app>
    """
  end
end
