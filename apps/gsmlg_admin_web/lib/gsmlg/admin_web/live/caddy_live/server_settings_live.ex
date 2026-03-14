defmodule GSMLG.AdminWeb.CaddyLive.ServerSettingsLive do
  @moduledoc """
  Caddy server command settings: configure system commands for start, stop, restart,
  and health check lifecycle operations (external mode only).
  """
  use GSMLG.AdminWeb, :live_view

  alias GSMLG.AdminWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:commands, load_commands())
     |> assign(:page_title, "Caddy Server Settings")
     |> assign(:active_menu, "caddy_server")}
  end

  @impl true
  def handle_event("save_commands", %{"commands" => params}, socket) do
    commands =
      [:start, :stop, :restart, :health_check]
      |> Enum.map(fn key -> {key, String.trim(Map.get(params, to_string(key), ""))} end)
      |> Enum.reject(fn {_, v} -> v == "" end)

    Application.put_env(:caddy, :commands, commands)

    {:noreply,
     socket
     |> assign(:commands, load_commands())
     |> put_flash(:info, "Commands saved")}
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.caddy flash={@flash} page_title={@page_title} active_menu={@active_menu}>
      <div class="p-6 space-y-6">
        <div class="flex items-center gap-3">
          <.link navigate={~p"/caddy/server"} class="btn btn-ghost btn-sm">
            <.dm_mdi name="arrow-left" class="size-4" />
          </.link>
          <h1 class="text-3xl font-bold">Server Settings</h1>
        </div>

        <div class="card bg-base-100 shadow">
          <div class="card-body space-y-4">
            <h2 class="card-title flex items-center gap-2">
              <.dm_mdi name="terminal" class="size-5 text-primary" />
              System Commands
            </h2>
            <p class="text-sm text-base-content/60">
              Shell commands executed for lifecycle operations in External mode.
              Exit code 0 = success, non-zero = failure with error output shown on Server Control.
            </p>
            <.form for={%{}} phx-submit="save_commands" class="space-y-4">
              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div class="form-control">
                  <label class="label">
                    <span class="label-text font-medium">
                      <.dm_mdi name="play" class="size-4 inline text-success" /> Start Command
                    </span>
                  </label>
                  <input
                    type="text"
                    name="commands[start]"
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
                    name="commands[stop]"
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
                    name="commands[restart]"
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
                    name="commands[health_check]"
                    value={@commands.health_check}
                    placeholder="systemctl is-active caddy"
                    class="input input-bordered w-full font-mono text-sm"
                  />
                </div>
              </div>

              <div class="pt-2">
                <button type="submit" class="btn btn-primary gap-2">
                  <.dm_mdi name="content-save" class="size-4" /> Save Commands
                </button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.caddy>
    """
  end
end
