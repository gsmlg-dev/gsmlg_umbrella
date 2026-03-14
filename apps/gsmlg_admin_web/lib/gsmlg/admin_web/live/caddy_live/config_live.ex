defmodule GSMLG.AdminWeb.CaddyLive.ConfigLive do
  @moduledoc """
  Caddy configuration editor: 3-part Caddyfile (global/additionals/sites)
  with validate, adapt, sync, backup, and restore operations.
  """
  use GSMLG.AdminWeb, :live_view

  alias GSMLG.AdminWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    mode = Caddy.Config.mode()
    config = load_config()

    socket =
      socket
      |> assign(:page_title, "Caddy Configuration")
      |> assign(:active_menu, "caddy_config")
      |> assign(:mode, mode)
      |> assign(:admin_url, Caddy.Config.admin_url())
      |> assign(:health_interval, Caddy.Config.health_interval())
      |> assign(:config_file_path, Application.get_env(:caddy, :config_file_path, "/etc/caddy/Caddyfile"))
      |> assign(:caddy_bin_path, safe_get_bin())
      |> assign(:caddy_bin_status, nil)
      |> assign(:show_config_file_modal, false)
      |> assign(:config_file_content, nil)
      |> assign(:config_file_error, nil)
      |> assign(:global, config.global || "")
      |> assign(:additionals, config.additionals || [])
      |> assign(:sites, config.sites || [])
      |> assign(:new_additional_name, "")
      |> assign(:new_additional_content, "")
      |> assign(:editing_additional, nil)
      |> assign(:new_site_address, "")
      |> assign(:new_site_config, "")
      |> assign(:editing_site, nil)
      |> assign(:active_tab, "global")
      |> assign(:validation_result, nil)
      |> assign(:adaptation_result, nil)

    {:ok, socket}
  end

  defp load_config do
    try do
      Caddy.get_config()
    rescue
      _ -> %Caddy.Config{}
    catch
      :exit, _ -> %Caddy.Config{}
    end
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def handle_event("save_config_file_path", %{"config_file_path" => path}, socket) do
    path = String.trim(path)
    Application.put_env(:caddy, :config_file_path, path)
    {:noreply, socket |> assign(:config_file_path, path) |> put_flash(:info, "Config file path saved")}
  end

  @impl true
  def handle_event("view_config_file", _params, socket) do
    path = socket.assigns.config_file_path

    {content, error} =
      case File.read(path) do
        {:ok, text} -> {text, nil}
        {:error, reason} -> {nil, "Cannot read #{path}: #{:file.format_error(reason)}"}
      end

    {:noreply,
     socket
     |> assign(:show_config_file_modal, true)
     |> assign(:config_file_content, content)
     |> assign(:config_file_error, error)}
  end

  @impl true
  def handle_event("close_config_file_modal", _params, socket) do
    {:noreply, assign(socket, :show_config_file_modal, false)}
  end

  @impl true
  def handle_event("save_caddy_bin_path", %{"caddy_bin_path" => path}, socket) do
    path = String.trim(path)

    {socket, status} =
      try do
        case Caddy.ConfigProvider.set_bin(path) do
          :ok ->
            {socket |> assign(:caddy_bin_path, path) |> put_flash(:info, "Caddy binary path saved"),
             {:ok, "Binary validated and saved"}}

          {:error, reason} ->
            {put_flash(socket, :error, "Invalid binary: #{reason}"), {:error, reason}}
        end
      rescue
        _ ->
          # ConfigProvider not running (Caddy disabled) — store path for later use
          Application.put_env(:caddy, :caddy_bin, path)
          {socket |> assign(:caddy_bin_path, path) |> put_flash(:info, "Caddy binary path saved (Caddy not running)"),
           {:ok, "Saved (Caddy not running)"}}
      catch
        :exit, _ ->
          Application.put_env(:caddy, :caddy_bin, path)
          {socket |> assign(:caddy_bin_path, path) |> put_flash(:info, "Caddy binary path saved (Caddy not running)"),
           {:ok, "Saved (Caddy not running)"}}
      end

    {:noreply, assign(socket, :caddy_bin_status, status)}
  end

  defp safe_get_bin do
    try do
      Caddy.ConfigProvider.get(:bin) || System.find_executable("caddy") || ""
    rescue
      _ -> System.find_executable("caddy") || ""
    catch
      :exit, _ -> System.find_executable("caddy") || ""
    end
  end

  @impl true
  def handle_event("update_global", %{"global" => global}, socket) do
    {:noreply, assign(socket, :global, global)}
  end

  @impl true
  def handle_event("save_global", %{"global" => global_content}, socket) do
    socket =
      try do
        Caddy.set_global(global_content)
        Caddy.save_config()
        saved_global = Caddy.get_global()

        socket
        |> assign(:global, saved_global)
        |> put_flash(:info, "Global options saved")
        |> assign(:validation_result, nil)
        |> assign(:adaptation_result, nil)
      rescue
        error ->
          socket
          |> assign(:global, global_content)
          |> put_flash(:error, "Failed to save: #{Exception.message(error)}")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_new_additional", %{"name" => name, "content" => content}, socket) do
    {:noreply, socket |> assign(:new_additional_name, name) |> assign(:new_additional_content, content)}
  end

  @impl true
  def handle_event("add_additional", %{"name" => name, "content" => content}, socket) do
    name = String.trim(name)

    socket =
      if name != "" do
        try do
          Caddy.add_additional(name, content)
          Caddy.save_config()
          additionals = Caddy.get_additionals()

          socket
          |> assign(:additionals, additionals)
          |> assign(:new_additional_name, "")
          |> assign(:new_additional_content, "")
          |> put_flash(:info, "Additional '#{name}' added")
        rescue
          error -> put_flash(socket, :error, "Failed to add additional: #{Exception.message(error)}")
        end
      else
        put_flash(socket, :error, "Additional name cannot be empty")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("edit_additional", %{"name" => name}, socket) do
    additional = Enum.find(socket.assigns.additionals, &(&1.name == name))
    {:noreply, assign(socket, :editing_additional, additional)}
  end

  @impl true
  def handle_event("cancel_edit_additional", _params, socket) do
    {:noreply, assign(socket, :editing_additional, nil)}
  end

  @impl true
  def handle_event("update_editing_additional", %{"content" => content}, socket) do
    editing = socket.assigns.editing_additional
    {:noreply, assign(socket, :editing_additional, %{editing | content: content})}
  end

  @impl true
  def handle_event("save_additional", %{"content" => content}, socket) do
    editing = socket.assigns.editing_additional

    socket =
      try do
        Caddy.update_additional(editing.name, content)
        Caddy.save_config()
        additionals = Caddy.get_additionals()

        socket
        |> assign(:additionals, additionals)
        |> assign(:editing_additional, nil)
        |> put_flash(:info, "Additional '#{editing.name}' updated")
      rescue
        error -> put_flash(socket, :error, "Failed to update additional: #{Exception.message(error)}")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("remove_additional", %{"name" => name}, socket) do
    socket =
      try do
        Caddy.remove_additional(name)
        Caddy.save_config()
        additionals = Caddy.get_additionals()

        socket
        |> assign(:additionals, additionals)
        |> put_flash(:info, "Additional '#{name}' removed")
      rescue
        error -> put_flash(socket, :error, "Failed to remove additional: #{Exception.message(error)}")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_new_site", %{"address" => address, "config" => config}, socket) do
    {:noreply, socket |> assign(:new_site_address, address) |> assign(:new_site_config, config)}
  end

  @impl true
  def handle_event("add_site", %{"address" => address, "config" => config}, socket) do
    address = String.trim(address)

    socket =
      if address != "" do
        try do
          Caddy.add_site(address, config)
          Caddy.save_config()
          sites = Caddy.get_sites()

          socket
          |> assign(:sites, sites)
          |> assign(:new_site_address, "")
          |> assign(:new_site_config, "")
          |> put_flash(:info, "Site '#{address}' added")
        rescue
          error -> put_flash(socket, :error, "Failed to add site: #{Exception.message(error)}")
        end
      else
        put_flash(socket, :error, "Site address cannot be empty")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("edit_site", %{"address" => address}, socket) do
    site = Enum.find(socket.assigns.sites, &(&1.address == address))
    {:noreply, assign(socket, :editing_site, site)}
  end

  @impl true
  def handle_event("cancel_edit_site", _params, socket) do
    {:noreply, assign(socket, :editing_site, nil)}
  end

  @impl true
  def handle_event("update_editing_site", %{"config" => config}, socket) do
    editing = socket.assigns.editing_site
    {:noreply, assign(socket, :editing_site, %{editing | config: config})}
  end

  @impl true
  def handle_event("save_site", %{"config" => config}, socket) do
    editing = socket.assigns.editing_site

    socket =
      try do
        Caddy.update_site(editing.address, config)
        Caddy.save_config()
        sites = Caddy.get_sites()

        socket
        |> assign(:sites, sites)
        |> assign(:editing_site, nil)
        |> put_flash(:info, "Site '#{editing.address}' updated")
      rescue
        error -> put_flash(socket, :error, "Failed to update site: #{Exception.message(error)}")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("remove_site", %{"address" => address}, socket) do
    socket =
      try do
        Caddy.remove_site(address)
        Caddy.save_config()
        sites = Caddy.get_sites()

        socket
        |> assign(:sites, sites)
        |> put_flash(:info, "Site '#{address}' removed")
      rescue
        error -> put_flash(socket, :error, "Failed to remove site: #{Exception.message(error)}")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("validate", _params, socket) do
    caddyfile = Caddy.get_caddyfile()

    socket =
      try do
        case Caddy.validate_caddyfile(caddyfile) do
          {:ok, _} -> assign(socket, :validation_result, {:success, "Configuration is valid"})
          {:error, reason} -> assign(socket, :validation_result, {:error, format_error(reason)})
        end
      rescue
        error -> assign(socket, :validation_result, {:error, Exception.message(error)})
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("adapt", _params, socket) do
    caddyfile = Caddy.get_caddyfile()

    socket =
      try do
        case Caddy.adapt(caddyfile) do
          {:ok, json} ->
            assign(socket, :adaptation_result, {:success, Jason.encode!(json, pretty: true)})

          {:error, reason} ->
            assign(socket, :adaptation_result, {:error, format_error(reason)})
        end
      rescue
        error -> assign(socket, :adaptation_result, {:error, Exception.message(error)})
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("sync", _params, socket) do
    socket =
      try do
        case Caddy.sync_to_caddy(backup: true) do
          :ok -> put_flash(socket, :info, "Configuration synced to Caddy (backup created)")
          {:error, reason} -> put_flash(socket, :error, "Sync failed: #{format_error(reason)}")
        end
      rescue
        error -> put_flash(socket, :error, "Sync failed: #{Exception.message(error)}")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("backup", _params, socket) do
    socket =
      try do
        case Caddy.backup_config() do
          :ok -> put_flash(socket, :info, "Configuration backed up successfully")
          {:error, reason} -> put_flash(socket, :error, "Backup failed: #{format_error(reason)}")
        end
      rescue
        error -> put_flash(socket, :error, "Backup failed: #{Exception.message(error)}")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("restore", _params, socket) do
    socket =
      try do
        case Caddy.restore_config() do
          {:ok, config} ->
            socket
            |> put_flash(:info, "Configuration restored from backup")
            |> assign(:global, config.global || "")
            |> assign(:additionals, config.additionals || [])
            |> assign(:sites, config.sites || [])
            |> assign(:validation_result, nil)
            |> assign(:adaptation_result, nil)

          {:error, reason} ->
            put_flash(socket, :error, "Restore failed: #{format_error(reason)}")
        end
      rescue
        error -> put_flash(socket, :error, "Restore failed: #{Exception.message(error)}")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("save_all", _params, socket) do
    socket =
      try do
        case Caddy.save_config() do
          :ok -> put_flash(socket, :info, "Configuration saved to disk")
          {:error, reason} -> put_flash(socket, :error, "Save failed: #{format_error(reason)}")
        end
      rescue
        error -> put_flash(socket, :error, "Save failed: #{Exception.message(error)}")
      end

    {:noreply, socket}
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error({:adaptation_failed, msg}), do: "Adaptation failed: #{msg}"
  defp format_error(reason), do: inspect(reason)

  defp assemble_caddyfile(global, additionals, sites) do
    parts =
      if global && String.trim(global) != "" do
        ["{\n" <> indent_content(global) <> "\n}"]
      else
        []
      end

    parts =
      Enum.reduce(additionals, parts, fn %{content: content}, acc ->
        if String.trim(content) != "", do: acc ++ [String.trim(content)], else: acc
      end)

    site_blocks =
      Enum.map(sites, fn site ->
        config = site.config || ""

        if String.trim(config) == "",
          do: "#{site.address} {\n}",
          else: "#{site.address} {\n" <> indent_content(config) <> "\n}"
      end)

    parts = parts ++ site_blocks

    if parts == [],
      do: "# Empty Caddyfile\n# Add global options, additionals, or sites to see the preview.",
      else: Enum.join(parts, "\n\n")
  end

  defp indent_content(content) do
    content
    |> String.trim()
    |> String.split("\n")
    |> Enum.map(&("  " <> &1))
    |> Enum.join("\n")
  end

  defp line_count(content) when is_binary(content) do
    content |> String.trim() |> String.split("\n") |> length()
  end

  defp line_count(_), do: 0

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.caddy flash={@flash} page_title={@page_title} active_menu={@active_menu}>
      <div class="p-6 space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-3xl font-bold">Configuration</h1>
            <p class="text-base-content/60 mt-1">
              Mode:
              <span class={["badge", if(@mode == :external, do: "badge-info", else: "badge-warning")]}>
                {@mode}
              </span>
            </p>
          </div>
        </div>

        <%= if @mode == :external do %>
          <div class="card bg-base-100 shadow">
            <div class="card-body space-y-4">
              <h2 class="card-title">
                <.dm_mdi name="signal" class="size-5" /> External Caddy Connection
              </h2>
              <div class="stats shadow">
                <div class="stat">
                  <div class="stat-title">Admin API URL</div>
                  <div class="stat-value text-lg font-mono">{@admin_url}</div>
                </div>
                <div class="stat">
                  <div class="stat-title">Health Interval</div>
                  <div class="stat-value text-lg">{div(@health_interval, 1000)}s</div>
                </div>
              </div>
              <div class="divider text-sm">Server Config File</div>
              <p class="text-sm text-base-content/60">
                Path to the Caddyfile used by the external Caddy process (e.g. <code class="font-mono">/etc/caddy/Caddyfile</code>).
              </p>
              <form phx-submit="save_config_file_path" class="flex gap-2 items-end">
                <div class="form-control flex-1">
                  <label class="label">
                    <span class="label-text font-medium">Config File Path</span>
                  </label>
                  <input
                    type="text"
                    name="config_file_path"
                    value={@config_file_path}
                    placeholder="/etc/caddy/Caddyfile"
                    class="input input-bordered w-full font-mono text-sm"
                  />
                </div>
                <button type="submit" class="btn btn-primary btn-sm">
                  <.dm_mdi name="content-save-outline" class="size-4" /> Save
                </button>
                <button type="button" phx-click="view_config_file" class="btn btn-outline btn-sm gap-1">
                  <.dm_mdi name="file-eye-outline" class="size-4" /> View File
                </button>
              </form>

              <div class="divider text-sm">Caddy Binary</div>
              <p class="text-sm text-base-content/60">
                Path to the <code class="font-mono">caddy</code> executable — used for <code class="font-mono">adapt</code> and <code class="font-mono">validate</code> operations.
              </p>
              <form phx-submit="save_caddy_bin_path" class="flex gap-2 items-end">
                <div class="form-control flex-1">
                  <label class="label">
                    <span class="label-text font-medium">Caddy Binary Path</span>
                  </label>
                  <input
                    type="text"
                    name="caddy_bin_path"
                    value={@caddy_bin_path}
                    placeholder="/usr/bin/caddy"
                    class="input input-bordered w-full font-mono text-sm"
                  />
                  <label class="label">
                    <span class="label-text-alt text-base-content/50">
                      Leave empty to use <code class="font-mono">caddy</code> from <code class="font-mono">$PATH</code>
                    </span>
                  </label>
                </div>
                <button type="submit" class="btn btn-primary btn-sm">
                  <.dm_mdi name="content-save-outline" class="size-4" /> Save
                </button>
              </form>
              <%= if @caddy_bin_status do %>
                <div class={["alert alert-sm", if(elem(@caddy_bin_status, 0) == :ok, do: "alert-success", else: "alert-error")]}>
                  <.dm_mdi name={if(elem(@caddy_bin_status, 0) == :ok, do: "check-circle-outline", else: "alert-circle-outline")} class="size-4" />
                  <span class="text-sm">{elem(@caddy_bin_status, 1)}</span>
                </div>
              <% end %>
            </div>
          </div>

          <%= if @show_config_file_modal do %>
            <div class="modal modal-open" phx-click-away="close_config_file_modal">
              <div class="modal-box max-w-4xl w-full" phx-click-away="">
                <div class="flex items-center justify-between mb-4">
                  <h3 class="font-bold text-lg flex items-center gap-2">
                    <.dm_mdi name="file-document-outline" class="size-5 text-primary" />
                    <span class="font-mono text-base">{@config_file_path}</span>
                  </h3>
                  <button class="btn btn-sm btn-ghost btn-circle" phx-click="close_config_file_modal">
                    <.dm_mdi name="close" class="size-5" />
                  </button>
                </div>
                <%= if @config_file_error do %>
                  <div class="alert alert-error">
                    <.dm_mdi name="alert-circle-outline" class="size-5" />
                    <span>{@config_file_error}</span>
                  </div>
                <% else %>
                  <div class="bg-base-200 rounded-lg p-4 overflow-auto max-h-[60vh]">
                    <pre class="text-sm font-mono whitespace-pre-wrap">{@config_file_content}</pre>
                  </div>
                  <div class="text-xs text-base-content/50 mt-2">
                    {String.split(@config_file_content || "", "\n") |> length()} lines
                  </div>
                <% end %>
                <div class="modal-action">
                  <button class="btn" phx-click="close_config_file_modal">Close</button>
                </div>
              </div>
            </div>
          <% end %>
        <% end %>

        <div class="flex justify-end gap-2">
          <button phx-click="backup" class="btn btn-outline btn-sm">
            <.dm_mdi name="archive-arrow-down-outline" class="size-4" /> Backup
          </button>
          <button phx-click="restore" class="btn btn-outline btn-sm">
            <.dm_mdi name="arrow-u-left-top" class="size-4" /> Restore
          </button>
          <button phx-click="save_all" class="btn btn-primary btn-sm">
            <.dm_mdi name="tray-arrow-down" class="size-4" /> Save to Disk
          </button>
        </div>

        <div role="tablist" class="tabs tabs-boxed">
          <button role="tab" class={["tab", @active_tab == "global" && "tab-active"]} phx-click="switch_tab" phx-value-tab="global">
            <.dm_mdi name="cog-outline" class="size-4 mr-2" /> Global Options
          </button>
          <button role="tab" class={["tab", @active_tab == "additionals" && "tab-active"]} phx-click="switch_tab" phx-value-tab="additionals">
            <.dm_mdi name="puzzle-outline" class="size-4 mr-2" /> Additionals
            <span class="badge badge-sm ml-1">{length(@additionals)}</span>
          </button>
          <button role="tab" class={["tab", @active_tab == "sites" && "tab-active"]} phx-click="switch_tab" phx-value-tab="sites">
            <.dm_mdi name="earth" class="size-4 mr-2" /> Sites
            <span class="badge badge-sm ml-1">{length(@sites)}</span>
          </button>
          <button role="tab" class={["tab", @active_tab == "preview" && "tab-active"]} phx-click="switch_tab" phx-value-tab="preview">
            <.dm_mdi name="eye-outline" class="size-4 mr-2" /> Preview
          </button>
        </div>

        <div :if={@active_tab == "global"} class="space-y-4">
          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title"><.dm_mdi name="cog-outline" class="size-5" /> Global Options</h2>
              <p class="text-sm text-base-content/60 mb-2">
                Content for the top-level <code>{"{ }"}</code> block (without outer braces).
              </p>
              <form phx-submit="save_global" phx-change="update_global">
                <textarea
                  name="global"
                  rows="10"
                  class="textarea textarea-bordered w-full font-mono text-sm"
                  placeholder="debug&#10;admin unix//tmp/caddy.sock"
                  phx-debounce="300"
                ><%= @global %></textarea>
                <div class="flex flex-wrap gap-2 mt-4">
                  <button type="submit" class="btn btn-primary btn-sm">
                    <.dm_mdi name="check" class="size-4" /> Save
                  </button>
                  <button type="button" phx-click="validate" class="btn btn-secondary btn-sm">
                    <.dm_mdi name="clipboard-check-outline" class="size-4" /> Validate
                  </button>
                  <button type="button" phx-click="adapt" class="btn btn-accent btn-sm">
                    <.dm_mdi name="code-brackets" class="size-4" /> Adapt to JSON
                  </button>
                  <button type="button" phx-click="sync" class="btn btn-info btn-sm">
                    <.dm_mdi name="refresh" class="size-4" /> Sync to Caddy
                  </button>
                </div>
              </form>
            </div>
          </div>
          <.validation_results validation_result={@validation_result} adaptation_result={@adaptation_result} />
        </div>

        <div :if={@active_tab == "additionals"} class="space-y-4">
          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title"><.dm_mdi name="plus-circle-outline" class="size-5" /> Add Additional</h2>
              <form phx-submit="add_additional" phx-change="update_new_additional">
                <div class="form-control">
                  <label class="label"><span class="label-text">Name</span></label>
                  <input type="text" name="name" value={@new_additional_name} class="input input-bordered font-mono" placeholder="common-headers" phx-debounce="300" />
                </div>
                <div class="form-control mt-2">
                  <label class="label"><span class="label-text">Content</span></label>
                  <textarea name="content" rows="4" class="textarea textarea-bordered w-full font-mono text-sm" phx-debounce="300"><%= @new_additional_content %></textarea>
                </div>
                <button type="submit" class="btn btn-primary btn-sm mt-4">
                  <.dm_mdi name="plus" class="size-4" /> Add
                </button>
              </form>
            </div>
          </div>

          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title"><.dm_mdi name="puzzle-outline" class="size-5" /> Configured Additionals</h2>
              <div :if={@additionals == []} class="alert alert-info">
                <.dm_mdi name="information-outline" class="size-5" />
                <span>No additionals configured yet.</span>
              </div>
              <div :if={@additionals != []} class="space-y-4">
                <%= for additional <- @additionals do %>
                  <div class="border border-base-300 rounded-lg p-4">
                    <%= if @editing_additional && @editing_additional.name == additional.name do %>
                      <form phx-submit="save_additional" class="space-y-3">
                        <div class="font-mono font-semibold text-primary">{additional.name}</div>
                        <textarea name="content" rows="4" class="textarea textarea-bordered w-full font-mono text-sm" phx-debounce="300"><%= @editing_additional.content %></textarea>
                        <div class="flex gap-2">
                          <button type="submit" class="btn btn-primary btn-sm"><.dm_mdi name="check" class="size-4" /> Save</button>
                          <button type="button" phx-click="cancel_edit_additional" class="btn btn-ghost btn-sm">Cancel</button>
                        </div>
                      </form>
                    <% else %>
                      <div class="flex items-start justify-between">
                        <div class="flex-1">
                          <div class="font-mono font-semibold text-primary">{additional.name}</div>
                          <pre class="text-xs font-mono text-base-content/70 mt-2 bg-base-200 p-2 rounded overflow-x-auto">{additional.content}</pre>
                        </div>
                        <div class="flex gap-1 ml-4">
                          <button phx-click="edit_additional" phx-value-name={additional.name} class="btn btn-ghost btn-xs">
                            <.dm_mdi name="pencil-outline" class="size-4" />
                          </button>
                          <button phx-click="remove_additional" phx-value-name={additional.name} class="btn btn-ghost btn-xs text-error" data-confirm={"Remove #{additional.name}?"}>
                            <.dm_mdi name="trash-can-outline" class="size-4" />
                          </button>
                        </div>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
          <.validation_results validation_result={@validation_result} adaptation_result={@adaptation_result} />
        </div>

        <div :if={@active_tab == "sites"} class="space-y-4">
          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title"><.dm_mdi name="plus-circle-outline" class="size-5" /> Add Site</h2>
              <form phx-submit="add_site" phx-change="update_new_site">
                <div class="form-control">
                  <label class="label"><span class="label-text">Site Address</span></label>
                  <input type="text" name="address" value={@new_site_address} class="input input-bordered font-mono" placeholder="example.com" phx-debounce="300" />
                </div>
                <div class="form-control mt-2">
                  <label class="label"><span class="label-text">Site Config</span></label>
                  <textarea name="config" rows="4" class="textarea textarea-bordered w-full font-mono text-sm" placeholder="reverse_proxy localhost:3000" phx-debounce="300"><%= @new_site_config %></textarea>
                </div>
                <button type="submit" class="btn btn-primary btn-sm mt-4">
                  <.dm_mdi name="plus" class="size-4" /> Add Site
                </button>
              </form>
            </div>
          </div>

          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title"><.dm_mdi name="earth" class="size-5" /> Configured Sites</h2>
              <div :if={@sites == []} class="alert alert-info">
                <.dm_mdi name="information-outline" class="size-5" />
                <span>No sites configured yet.</span>
              </div>
              <div :if={@sites != []} class="space-y-4">
                <%= for site <- @sites do %>
                  <div class="border border-base-300 rounded-lg p-4">
                    <%= if @editing_site && @editing_site.address == site.address do %>
                      <form phx-submit="save_site" class="space-y-3">
                        <div class="font-mono font-semibold text-primary">{site.address}</div>
                        <textarea name="config" rows="4" class="textarea textarea-bordered w-full font-mono text-sm" phx-debounce="300"><%= @editing_site.config %></textarea>
                        <div class="flex gap-2">
                          <button type="submit" class="btn btn-primary btn-sm"><.dm_mdi name="check" class="size-4" /> Save</button>
                          <button type="button" phx-click="cancel_edit_site" class="btn btn-ghost btn-sm">Cancel</button>
                        </div>
                      </form>
                    <% else %>
                      <div class="flex items-start justify-between">
                        <div class="flex-1">
                          <div class="font-mono font-semibold text-primary">{site.address}</div>
                          <pre class="text-xs font-mono text-base-content/70 mt-2 bg-base-200 p-2 rounded overflow-x-auto">{site.config}</pre>
                        </div>
                        <div class="flex gap-1 ml-4">
                          <button phx-click="edit_site" phx-value-address={site.address} class="btn btn-ghost btn-xs">
                            <.dm_mdi name="pencil-outline" class="size-4" />
                          </button>
                          <button phx-click="remove_site" phx-value-address={site.address} class="btn btn-ghost btn-xs text-error" data-confirm={"Remove #{site.address}?"}>
                            <.dm_mdi name="trash-can-outline" class="size-4" />
                          </button>
                        </div>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
          <.validation_results validation_result={@validation_result} adaptation_result={@adaptation_result} />
        </div>

        <div :if={@active_tab == "preview"} class="space-y-4">
          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <div class="flex items-center justify-between">
                <h2 class="card-title"><.dm_mdi name="eye-outline" class="size-5" /> Caddyfile Preview</h2>
                <div class="flex gap-2">
                  <button phx-click="validate" class="btn btn-secondary btn-sm"><.dm_mdi name="clipboard-check-outline" class="size-4" /> Validate</button>
                  <button phx-click="sync" class="btn btn-info btn-sm"><.dm_mdi name="refresh" class="size-4" /> Sync</button>
                </div>
              </div>
              <div class="bg-base-200 rounded-lg p-4 overflow-auto max-h-[600px] mt-4">
                <pre class="text-sm font-mono whitespace-pre-wrap"><%= assemble_caddyfile(@global, @additionals, @sites) %></pre>
              </div>
              <div class="flex items-center gap-4 text-sm text-base-content/60 mt-4">
                <span class="badge badge-outline badge-sm">Global: {line_count(@global)} lines</span>
                <span class="badge badge-outline badge-sm">Additionals: {length(@additionals)}</span>
                <span class="badge badge-outline badge-sm">Sites: {length(@sites)}</span>
              </div>
            </div>
          </div>
          <.validation_results validation_result={@validation_result} adaptation_result={@adaptation_result} />
        </div>
      </div>
    </Layouts.caddy>
    """
  end

  defp validation_results(assigns) do
    ~H"""
    <div :if={@validation_result} class="card bg-base-100 shadow">
      <div class="card-body">
        <h3 class="card-title text-lg">Validation Result</h3>
        <div :if={elem(@validation_result, 0) == :success} class="alert alert-success">
          <.dm_mdi name="check-circle-outline" class="size-5" />
          <span>{elem(@validation_result, 1)}</span>
        </div>
        <div :if={elem(@validation_result, 0) == :error} class="alert alert-error">
          <.dm_mdi name="alert-circle-outline" class="size-5" />
          <pre class="text-xs overflow-x-auto">{elem(@validation_result, 1)}</pre>
        </div>
      </div>
    </div>

    <div :if={@adaptation_result} class="card bg-base-100 shadow">
      <div class="card-body">
        <h3 class="card-title text-lg">Adapted JSON</h3>
        <div :if={elem(@adaptation_result, 0) == :success}>
          <div class="alert alert-success mb-4">
            <.dm_mdi name="check-circle-outline" class="size-5" /> <span>Successfully adapted</span>
          </div>
          <div class="bg-base-200 rounded-lg p-4 overflow-x-auto max-h-96">
            <pre class="text-xs font-mono">{elem(@adaptation_result, 1)}</pre>
          </div>
        </div>
        <div :if={elem(@adaptation_result, 0) == :error} class="alert alert-error">
          <.dm_mdi name="alert-circle-outline" class="size-5" />
          <pre class="text-xs overflow-x-auto">{elem(@adaptation_result, 1)}</pre>
        </div>
      </div>
    </div>
    """
  end
end
