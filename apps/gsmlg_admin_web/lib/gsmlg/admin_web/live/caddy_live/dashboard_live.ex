defmodule GSMLG.AdminWeb.CaddyLive.DashboardLive do
  @moduledoc """
  Caddy management dashboard showing real-time state, mode, readiness,
  configuration status, and sync status. Supports enabling/disabling and
  reconfiguring Caddy at runtime without an application restart.
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
  def handle_event("enable", %{"caddy" => params}, socket) do
    apply_config(params, start: true)
    restart_caddy_supervisor()
    {:noreply, assign_caddy_state(socket)}
  end

  @impl true
  def handle_event("disable", _params, socket) do
    Application.put_env(:caddy, :start, false)
    stop_caddy_supervisor()
    {:noreply, assign_caddy_state(socket)}
  end

  @impl true
  def handle_event("save_settings", %{"caddy" => params}, socket) do
    apply_config(params, start: true)
    restart_caddy_supervisor()
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

  defp apply_config(params, extra) do
    mode = params["mode"] || "external"
    admin_url = params["admin_url"] || "http://localhost:2019"
    health_interval = parse_positive_integer(params["health_interval"], 15_000)

    Application.put_env(:caddy, :start, Keyword.get(extra, :start, true))
    Application.put_env(:caddy, :mode, String.to_atom(mode))
    Application.put_env(:caddy, :admin_url, admin_url)
    Application.put_env(:caddy, :health_interval, health_interval)

    commands =
      [:start, :stop, :restart, :health_check]
      |> Enum.map(fn key ->
        val = get_in(params, ["commands", to_string(key)]) || ""
        {key, String.trim(val)}
      end)
      |> Enum.reject(fn {_, v} -> v == "" end)

    Application.put_env(:caddy, :commands, commands)
  end

  defp load_commands do
    cmds = Application.get_env(:caddy, :commands, [])

    %{
      start: Keyword.get(cmds, :start, ""),
      stop: Keyword.get(cmds, :stop, ""),
      restart: Keyword.get(cmds, :restart, ""),
      health_check: Keyword.get(cmds, :health_check, "")
    }
  end

  defp reload_caddy_modules do
    modules = [
      Caddy.Admin.Request,
      Caddy.Server.External,
      Caddy.Admin.Api
    ]

    Enum.each(modules, fn mod ->
      :code.soft_purge(mod)
      :code.load_file(mod)
    end)
  end

  defp restart_caddy_supervisor do
    reload_caddy_modules()

    case Process.whereis(Caddy.Application) do
      nil ->
        # Caddy.Application supervisor is dead — restart the whole OTP app
        Application.stop(:caddy)
        Application.start(:caddy)

      _pid ->
        Supervisor.terminate_child(Caddy.Application, Caddy.Supervisor)
        Supervisor.restart_child(Caddy.Application, Caddy.Supervisor)
    end
  end

  defp stop_caddy_supervisor do
    case Process.whereis(Caddy.Application) do
      nil -> :ok
      _pid -> Supervisor.terminate_child(Caddy.Application, Caddy.Supervisor)
    end
  end

  defp parse_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_positive_integer(_, default), do: default

  defp assign_caddy_state(socket) do
    enabled = Application.get_env(:caddy, :start, false)
    mode = Application.get_env(:caddy, :mode, :external)
    admin_url = Application.get_env(:caddy, :admin_url, "http://localhost:2019")
    health_interval = Application.get_env(:caddy, :health_interval, 15_000)

    socket
    |> assign(:enabled, enabled)
    |> assign(:mode, mode)
    |> assign(:admin_url, admin_url)
    |> assign(:health_interval, health_interval)
    |> assign(:commands, load_commands())
    |> assign(:state, if(enabled, do: safe_get_state(), else: :disabled))
    |> assign(:ready, if(enabled, do: safe_check_ready(), else: false))
    |> assign(:configured, if(enabled, do: safe_check_configured(), else: false))
    |> assign(:sync_status, if(enabled, do: safe_check_sync_status(), else: :disabled))
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

  defp toml_example do
    "[caddy]\nstart = true\nmode = \"external\"\nadmin_url = \"http://localhost:2019\"\nhealth_interval = 15000"
  end

  defp state_badge_class(:disabled), do: "badge-ghost"
  defp state_badge_class(:unconfigured), do: "badge-warning"
  defp state_badge_class(:configured), do: "badge-info"
  defp state_badge_class(:synced), do: "badge-success"
  defp state_badge_class(:degraded), do: "badge-error"
  defp state_badge_class(:unavailable), do: "badge-error"
  defp state_badge_class(_), do: "badge-ghost"

  defp state_label(:disabled), do: "Disabled"
  defp state_label(:unconfigured), do: "Unconfigured"
  defp state_label(:configured), do: "Configured"
  defp state_label(:synced), do: "Synced"
  defp state_label(:degraded), do: "Degraded"
  defp state_label(:unavailable), do: "Unavailable"
  defp state_label(state), do: to_string(state)

  defp format_mode(:embedded), do: "Embedded"
  defp format_mode(:external), do: "External"
  defp format_mode(mode), do: to_string(mode)

  defp format_sync_status(:disabled), do: {:disabled, "Caddy module is disabled"}
  defp format_sync_status({:ok, :in_sync}), do: {:ok, "In sync"}

  defp format_sync_status({:ok, {:drift_detected, diff}}),
    do: {:drift, "Drift detected (#{map_size(diff)} differences)"}

  defp format_sync_status({:error, :unavailable}), do: {:error, "Caddy not reachable"}
  defp format_sync_status({:error, :caddy_not_available}), do: {:error, "Caddy not reachable at #{Application.get_env(:caddy, :admin_url, "http://localhost:2019")}"}
  defp format_sync_status({:error, {:adaptation_failed, _}}), do: {:info, "No Caddyfile configured yet — add routes in the Configuration page"}
  defp format_sync_status({:error, reason}) when is_binary(reason), do: {:error, reason}
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

        <%= if not @enabled do %>
          <div class="alert alert-info">
            <.dm_mdi name="information-outline" class="size-6 shrink-0" />
            <div>
              <p class="font-semibold">Caddy module is disabled</p>
              <p class="text-sm mt-1">
                Configure and enable it below, or set
                <code class="font-mono">start = true</code>
                in the <code class="font-mono">[caddy]</code>
                section of your TOML file for persistence across restarts.
              </p>
            </div>
          </div>

          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title flex items-center gap-2">
                <.dm_mdi name="power" class="size-5 text-primary" /> Enable Caddy
              </h2>
              <p class="text-sm text-base-content/60 mb-4">
                Configure the connection settings and start the Caddy integration.
                Changes apply immediately but are not persisted to the TOML file.
              </p>
              <.form for={%{}} phx-submit="enable" class="space-y-4">
                <.caddy_settings_fields mode={@mode} admin_url={@admin_url} health_interval={@health_interval} commands={@commands} />
                <div class="flex items-center gap-3 pt-2">
                  <button type="submit" class="btn btn-success gap-2">
                    <.dm_mdi name="power" class="size-5" /> Enable Caddy
                  </button>
                </div>
              </.form>
              <div class="divider text-xs text-base-content/40">TOML example for persistence</div>
              <pre class="bg-base-200 rounded p-3 text-xs font-mono">{toml_example()}</pre>
            </div>
          </div>
        <% else %>
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
                <% {:info, message} -> %>
                  <div class="alert alert-info">
                    <.dm_mdi name="information-outline" class="size-5" />
                    <span>{message}</span>
                  </div>
                <% {:disabled, _} -> %>
                  <div class="alert">
                    <.dm_mdi name="minus-circle-outline" class="size-5" />
                    <span>Not available — Caddy module is disabled</span>
                  </div>
              <% end %>
            </div>
          </div>

          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title flex items-center gap-2">
                <.dm_mdi name="cog-outline" class="size-5 text-primary" /> Settings
              </h2>
              <p class="text-sm text-base-content/60 mb-4">
                Changes apply immediately but are not persisted to the TOML file.
              </p>
              <.form for={%{}} phx-submit="save_settings" class="space-y-4">
                <.caddy_settings_fields mode={@mode} admin_url={@admin_url} health_interval={@health_interval} commands={@commands} />
                <div class="flex items-center gap-3 pt-2">
                  <button type="submit" class="btn btn-primary gap-2">
                    <.dm_mdi name="content-save-outline" class="size-5" /> Save & Restart
                  </button>
                  <button type="button" phx-click="disable" class="btn btn-error btn-outline gap-2">
                    <.dm_mdi name="power-off" class="size-5" /> Disable Caddy
                  </button>
                </div>
              </.form>
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
        <% end %>
      </div>
    </Layouts.caddy>
    """
  end

  defp caddy_settings_fields(assigns) do
    ~H"""
    <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
      <div class="form-control">
        <label class="label">
          <span class="label-text font-medium">Mode</span>
        </label>
        <select name="caddy[mode]" class="select select-bordered w-full">
          <option value="external" selected={to_string(@mode) == "external"}>
            External (systemd / OS managed)
          </option>
          <option value="embedded" selected={to_string(@mode) == "embedded"}>
            Embedded (binary managed by this app)
          </option>
        </select>
      </div>

      <div class="form-control">
        <label class="label">
          <span class="label-text font-medium">Admin URL</span>
        </label>
        <input
          type="text"
          name="caddy[admin_url]"
          value={@admin_url}
          placeholder="http://localhost:2019"
          class="input input-bordered w-full font-mono"
        />
        <label class="label">
          <span class="label-text-alt text-base-content/50">
            TCP: http://host:port — Unix: unix:///path/to/caddy.sock
          </span>
        </label>
      </div>

      <div class="form-control">
        <label class="label">
          <span class="label-text font-medium">Health Check Interval (ms)</span>
        </label>
        <input
          type="number"
          name="caddy[health_interval]"
          value={@health_interval}
          min="1000"
          step="1000"
          class="input input-bordered w-full"
        />
      </div>
    </div>

    <%= if to_string(@mode) == "external" do %>
      <div class="divider text-sm">System Commands (External Mode)</div>
      <p class="text-xs text-base-content/60 -mt-2 mb-2">
        Shell commands for lifecycle operations. Exit code 0 = success, non-zero = failure with error output.
      </p>
      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <div class="form-control">
          <label class="label">
            <span class="label-text font-medium">
              <.dm_mdi name="play" class="size-4 inline text-success" /> Start Command
            </span>
          </label>
          <input
            type="text"
            name="caddy[commands][start]"
            value={@commands.start}
            placeholder="systemctl start caddy"
            class="input input-bordered w-full font-mono text-sm"
          />
        </div>

        <div class="form-control">
          <label class="label">
            <span class="label-text font-medium">
              <.dm_mdi name="stop" class="size-4 inline text-error" /> Stop Command
            </span>
          </label>
          <input
            type="text"
            name="caddy[commands][stop]"
            value={@commands.stop}
            placeholder="systemctl stop caddy"
            class="input input-bordered w-full font-mono text-sm"
          />
        </div>

        <div class="form-control">
          <label class="label">
            <span class="label-text font-medium">
              <.dm_mdi name="refresh" class="size-4 inline text-warning" /> Restart Command
            </span>
          </label>
          <input
            type="text"
            name="caddy[commands][restart]"
            value={@commands.restart}
            placeholder="systemctl restart caddy"
            class="input input-bordered w-full font-mono text-sm"
          />
        </div>

        <div class="form-control">
          <label class="label">
            <span class="label-text font-medium">
              <.dm_mdi name="heart-pulse" class="size-4 inline text-info" /> Health Check Command
            </span>
          </label>
          <input
            type="text"
            name="caddy[commands][health_check]"
            value={@commands.health_check}
            placeholder="systemctl is-active caddy"
            class="input input-bordered w-full font-mono text-sm"
          />
        </div>
      </div>
    <% end %>
    """
  end
end
