defmodule GSMLG.AdminWeb.CaddyLive.ServerLive do
  @moduledoc """
  Caddy server control: start/stop/restart, health checks, and server info.
  """
  use GSMLG.AdminWeb, :live_view

  alias GSMLG.AdminWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    mode = Application.get_env(:caddy, :mode, :external)
    admin_url = Application.get_env(:caddy, :admin_url, "http://localhost:2019")

    socket =
      socket
      |> assign(:mode, mode)
      |> assign(:admin_url, admin_url)
      |> assign(:status, :unknown)
      |> assign(:server_info, nil)
      |> assign(:error, nil)
      |> assign(:page_title, "Caddy Server Control")
      |> assign(:active_menu, "caddy_server")
      |> load_server_status()
      |> load_server_info()

    {:ok, socket}
  end

  @impl true
  def handle_event("check_status", _params, socket) do
    {:noreply, load_server_status(socket)}
  end

  @impl true
  def handle_event("health_check", _params, socket) do
    socket =
      try do
        result = Caddy.Server.External.health_check()
        assign(socket, :error, "Health check result: #{inspect(result)}")
      rescue
        e -> assign(socket, :error, "Health check failed: #{Exception.message(e)}")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("execute_command", %{"command" => command}, socket) do
    command_atom = String.to_existing_atom(command)

    socket =
      try do
        case Caddy.Server.execute_command(command_atom) do
          :ok ->
            socket
            |> assign(:error, nil)
            |> put_flash(:info, "Command '#{command}' executed successfully")
            |> load_server_status()

          {:ok, _result} ->
            socket
            |> assign(:error, nil)
            |> put_flash(:info, "Command '#{command}' executed successfully")
            |> load_server_status()

          {:error, reason} ->
            assign(socket, :error, "Command failed: #{inspect(reason)}")
        end
      rescue
        e -> assign(socket, :error, "Command execution failed: #{Exception.message(e)}")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("restart_server", _params, socket) do
    socket =
      try do
        case Caddy.restart_server() do
          :ok ->
            socket
            |> assign(:error, nil)
            |> put_flash(:info, "Server restarted successfully")
            |> load_server_status()
            |> load_server_info()

          {:ok, _} ->
            socket
            |> assign(:error, nil)
            |> put_flash(:info, "Server restarted successfully")
            |> load_server_status()
            |> load_server_info()

          {:error, reason} ->
            assign(socket, :error, "Restart failed: #{inspect(reason)}")
        end
      rescue
        e -> assign(socket, :error, "Restart failed: #{Exception.message(e)}")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("stop_server", _params, socket) do
    socket =
      try do
        case Caddy.stop() do
          :ok ->
            socket
            |> assign(:error, nil)
            |> put_flash(:info, "Server stopped successfully")
            |> load_server_status()

          {:error, reason} ->
            assign(socket, :error, "Stop failed: #{inspect(reason)}")
        end
      rescue
        e -> assign(socket, :error, "Stop failed: #{Exception.message(e)}")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh_server_info", _params, socket) do
    {:noreply, load_server_info(socket)}
  end

  defp load_server_status(socket) do
    status =
      try do
        Caddy.Server.check_status()
      rescue
        _ -> :unknown
      catch
        :exit, _ -> :unknown
      end

    assign(socket, :status, status)
  end

  defp load_server_info(socket) do
    server_info =
      try do
        case Caddy.Admin.Api.server_info() do
          {:ok, info} -> info
          _ -> nil
        end
      rescue
        _ -> nil
      catch
        :exit, _ -> nil
      end

    assign(socket, :server_info, server_info)
  end

  defp status_badge_class(:running), do: "badge-success"
  defp status_badge_class(:stopped), do: "badge-error"
  defp status_badge_class(:unknown), do: "badge-warning"
  defp status_badge_class(_), do: "badge-ghost"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.caddy flash={@flash} page_title={@page_title} active_menu={@active_menu}>
      <div class="p-6 space-y-6">
        <div class="flex items-center justify-between">
          <h1 class="text-3xl font-bold">Server Control</h1>
          <div class={["badge badge-lg", if(@mode == :external, do: "badge-primary", else: "badge-secondary")]}>
            Mode: {@mode}
          </div>
        </div>

        <div :if={@error} class="alert alert-error">
          <.dm_mdi name="close-circle-outline" class="size-5" />
          <span>{@error}</span>
        </div>

        <div class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title">Server Status</h2>
            <div class="flex items-center gap-4">
              <div class={["badge badge-lg", status_badge_class(@status)]}>
                {String.upcase(to_string(@status))}
              </div>
              <button class="btn btn-sm btn-outline" phx-click="check_status">
                Refresh Status
              </button>
            </div>
          </div>
        </div>

        <%= if @mode == :external do %>
          <div class="card bg-base-100 shadow">
            <div class="card-body space-y-4">
              <h2 class="card-title">External Mode Controls</h2>
              <div>
                <div class="text-sm font-semibold mb-1">Admin URL</div>
                <div class="badge badge-outline font-mono">{@admin_url}</div>
              </div>
              <div class="divider">Lifecycle Commands</div>
              <div class="flex gap-2 flex-wrap">
                <button class="btn btn-success btn-sm" phx-click="execute_command" phx-value-command="start">
                  <.dm_mdi name="play" class="size-4" /> Start
                </button>
                <button class="btn btn-error btn-sm" phx-click="execute_command" phx-value-command="stop">
                  <.dm_mdi name="stop" class="size-4" /> Stop
                </button>
                <button class="btn btn-warning btn-sm" phx-click="execute_command" phx-value-command="restart">
                  <.dm_mdi name="refresh" class="size-4" /> Restart
                </button>
              </div>
              <div class="divider">Health & Diagnostics</div>
              <div class="flex gap-2 flex-wrap">
                <button class="btn btn-info btn-sm" phx-click="health_check">
                  <.dm_mdi name="heart-pulse" class="size-4" /> Health Check
                </button>
              </div>
            </div>
          </div>
        <% else %>
          <div class="card bg-base-100 shadow">
            <div class="card-body space-y-4">
              <h2 class="card-title">Embedded Mode Controls</h2>
              <div class="flex gap-2 flex-wrap">
                <button class="btn btn-warning btn-sm" phx-click="restart_server">
                  <.dm_mdi name="refresh" class="size-4" /> Restart Server
                </button>
                <button class="btn btn-error btn-sm" phx-click="stop_server">
                  <.dm_mdi name="stop" class="size-4" /> Stop Server
                </button>
              </div>
            </div>
          </div>
        <% end %>

        <div class="card bg-base-100 shadow">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <h2 class="card-title">
                <.dm_mdi name="information-outline" class="size-5 text-primary" />
                Server Information
              </h2>
              <button class="btn btn-sm btn-outline" phx-click="refresh_server_info">
                <.dm_mdi name="refresh" class="size-4" /> Refresh
              </button>
            </div>
            <%= if @server_info do %>
              <pre class="bg-base-200 p-4 rounded-lg text-xs overflow-auto max-h-96">{Jason.encode!(@server_info, pretty: true)}</pre>
            <% else %>
              <div class="text-center py-8 text-base-content/50">
                <p>No server information available.</p>
                <p class="text-sm">Server may not be running or Admin API may be unreachable.</p>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.caddy>
    """
  end
end
