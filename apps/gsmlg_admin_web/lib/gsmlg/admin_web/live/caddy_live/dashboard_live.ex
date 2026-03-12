defmodule GSMLG.AdminWeb.CaddyLive.DashboardLive do
  @moduledoc """
  Caddy management dashboard showing real-time state, mode, readiness,
  configuration status, and sync status.
  """
  use GSMLG.AdminWeb, :live_view

  alias GSMLG.AdminWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      GSMLG.AdminWeb.CaddyTelemetryCollector.subscribe()
    end

    {:ok, assign_caddy_state(socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign_caddy_state(socket)}
  end

  @impl true
  def handle_info({:caddy_telemetry, entry}, socket) do
    socket =
      if entry.event == [:caddy, :config_manager, :state_changed] do
        assign_caddy_state(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  defp assign_caddy_state(socket) do
    socket
    |> assign(:state, safe_get_state())
    |> assign(:mode, get_mode())
    |> assign(:ready, safe_check_ready())
    |> assign(:configured, safe_check_configured())
    |> assign(:sync_status, safe_check_sync_status())
    |> assign(:page_title, "Caddy Dashboard")
    |> assign(:active_menu, "caddy_dashboard")
  end

  defp safe_get_state do
    try do
      Caddy.get_state()
    rescue
      _ -> :unavailable
    catch
      :exit, _ -> :unavailable
    end
  end

  defp get_mode, do: Application.get_env(:caddy, :mode, :external)

  defp safe_check_ready do
    try do
      Caddy.ready?()
    rescue
      _ -> false
    catch
      :exit, _ -> false
    end
  end

  defp safe_check_configured do
    try do
      Caddy.configured?()
    rescue
      _ -> false
    catch
      :exit, _ -> false
    end
  end

  defp safe_check_sync_status do
    try do
      Caddy.check_sync_status()
    rescue
      _ -> {:error, :unavailable}
    catch
      :exit, _ -> {:error, :unavailable}
    end
  end

  defp state_badge_class(:unconfigured), do: "badge-warning"
  defp state_badge_class(:configured), do: "badge-info"
  defp state_badge_class(:synced), do: "badge-success"
  defp state_badge_class(:degraded), do: "badge-error"
  defp state_badge_class(:unavailable), do: "badge-ghost"
  defp state_badge_class(_), do: "badge-ghost"

  defp state_label(:unconfigured), do: "Unconfigured"
  defp state_label(:configured), do: "Configured"
  defp state_label(:synced), do: "Synced"
  defp state_label(:degraded), do: "Degraded"
  defp state_label(:unavailable), do: "Unavailable"
  defp state_label(state), do: to_string(state)

  defp format_mode(:embedded), do: "Embedded"
  defp format_mode(:external), do: "External"
  defp format_mode(mode), do: to_string(mode)

  defp format_sync_status({:ok, :in_sync}), do: {:ok, "In sync"}

  defp format_sync_status({:ok, {:drift_detected, diff}}),
    do: {:drift, "Drift detected (#{map_size(diff)} differences)"}

  defp format_sync_status({:error, :unavailable}), do: {:error, "Unavailable"}
  defp format_sync_status({:error, reason}), do: {:error, "Error: #{inspect(reason)}"}
  defp format_sync_status(_), do: {:error, "Unknown"}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.caddy flash={@flash} page_title={@page_title} active_menu={@active_menu}>
      <div class="p-6 space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-3xl font-bold">Caddy Dashboard</h1>
            <p class="text-base-content/60 mt-1">Reverse proxy status and monitoring</p>
          </div>
          <button phx-click="refresh" class="btn btn-primary btn-sm gap-2">
            <.dm_mdi name="refresh" class="size-4" /> Refresh
          </button>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title text-base">Application State</h2>
              <div class={["badge badge-lg mt-2", state_badge_class(@state)]}>
                {state_label(@state)}
              </div>
              <p class="text-xs text-base-content/60 mt-2">Current operational state</p>
            </div>
          </div>

          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title text-base">Operating Mode</h2>
              <div class="flex items-center gap-3 mt-2">
                <.dm_mdi
                  name={if @mode == :embedded, do: "cube-outline", else: "cloud-outline"}
                  class="size-8 text-primary"
                />
                <span class="text-2xl font-bold">{format_mode(@mode)}</span>
              </div>
              <p class="text-xs text-base-content/60 mt-2">Server management mode</p>
            </div>
          </div>

          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title text-base">Ready Status</h2>
              <div class={[
                "badge badge-lg mt-2",
                if(@ready, do: "badge-success", else: "badge-error")
              ]}>
                <.dm_mdi
                  name={if @ready, do: "check-circle-outline", else: "close-circle-outline"}
                  class="size-4 mr-1"
                />
                {if @ready, do: "Ready", else: "Not Ready"}
              </div>
              <p class="text-xs text-base-content/60 mt-2">Server readiness check</p>
            </div>
          </div>

          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title text-base">Configuration</h2>
              <div class={[
                "badge badge-lg mt-2",
                if(@configured, do: "badge-success", else: "badge-warning")
              ]}>
                <.dm_mdi
                  name={if @configured, do: "check-circle-outline", else: "alert-outline"}
                  class="size-4 mr-1"
                />
                {if @configured, do: "Configured", else: "Not Configured"}
              </div>
              <p class="text-xs text-base-content/60 mt-2">Configuration status</p>
            </div>
          </div>
        </div>

        <div class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title flex items-center gap-2">
              <.dm_mdi name="sync" class="size-5 text-primary" />
              Synchronization Status
            </h2>
            <%= case format_sync_status(@sync_status) do %>
              <% {:ok, message} -> %>
                <div class="alert alert-success">
                  <.dm_mdi name="check-circle-outline" class="size-5" />
                  <span>{message}</span>
                </div>
              <% {:drift, message} -> %>
                <div class="alert alert-warning">
                  <.dm_mdi name="alert-outline" class="size-5" />
                  <span>{message}</span>
                </div>
              <% {:error, message} -> %>
                <div class="alert alert-error">
                  <.dm_mdi name="close-circle-outline" class="size-5" />
                  <span>{message}</span>
                </div>
            <% end %>
          </div>
        </div>

        <div class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title flex items-center gap-2">
              <.dm_mdi name="lightning-bolt" class="size-5 text-primary" /> Quick Actions
            </h2>
            <div class="flex flex-wrap gap-3 mt-3">
              <.link navigate={~p"/caddy/config"} class="btn btn-outline gap-2">
                <.dm_mdi name="text-box-outline" class="size-5" /> Configuration
              </.link>
              <.link navigate={~p"/caddy/server"} class="btn btn-outline gap-2">
                <.dm_mdi name="cog-outline" class="size-5" /> Server Control
              </.link>
              <.link navigate={~p"/caddy/metrics"} class="btn btn-outline gap-2">
                <.dm_mdi name="chart-bar" class="size-5" /> Metrics
              </.link>
              <.link navigate={~p"/caddy/logs"} class="btn btn-outline gap-2">
                <.dm_mdi name="file-search-outline" class="size-5" /> Logs
              </.link>
            </div>
          </div>
        </div>
      </div>
    </Layouts.caddy>
    """
  end
end
