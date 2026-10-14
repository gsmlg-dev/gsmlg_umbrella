defmodule GSMLG.AdminWeb.GaoNoteLive.SettingsLive do
  use GSMLG.AdminWeb, :user_live_view

  alias GSMLG.Accounts.User
  alias GSMLG.Config.{GaoNoteSettings, Schema}

  @invalid_path "Use only letters, numbers, hyphens (-), and underscores (_)."

  @impl true
  def mount(_params, _session, %{assigns: %{current_user: %User{}}} = socket) do
    {:ok,
     socket
     |> assign(:page_title, "GaoNote Settings")
     |> assign(:active_menu, "gao_note_settings")
     |> assign_form(GaoNoteSettings.storage_path(), [])}
  end

  def mount(_params, _session, socket) do
    {:ok, redirect(socket, to: "/sign_in")}
  end

  @impl true
  def handle_event("validate", %{"gao_note" => params}, socket) do
    path = Map.get(params, "storage_path", "")

    {:noreply,
     socket
     |> clear_flash()
     |> assign_form(path, validation_errors(path))}
  end

  def handle_event("save", %{"gao_note" => params}, %{assigns: %{current_user: %User{}}} = socket) do
    path = Map.get(params, "storage_path", "")
    errors = validation_errors(path)
    socket = socket |> clear_flash() |> assign_form(path, errors)

    if errors == [] do
      case GaoNoteSettings.save_storage_path(path) do
        {:ok, applied_path} ->
          {:noreply,
           socket
           |> assign_form(applied_path, [])
           |> put_flash(:info, "GaoNote settings saved.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, save_error(reason))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("save", _params, socket) do
    {:noreply, redirect(socket, to: "/sign_in")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} active_menu={@active_menu}>
      <div class="bg-surface p-4 text-on-surface sm:p-6">
        <div class="mx-auto grid max-w-3xl gap-6">
          <header class="grid gap-2">
            <h1 class="text-3xl font-bold">GaoNote Settings</h1>
            <p class="text-sm text-on-surface-variant">
              Configure where GaoNote stores attachments.
            </p>
          </header>

          <.dm_card variant="bordered" body_class="grid gap-6">
            <:title>Attachment storage</:title>
            <p class="text-sm text-on-surface-variant">
              Changes are saved to TOML and take effect immediately.
              Changing the storage path does not move existing attachments.
            </p>
            <.form
              for={@form}
              id="gao-note-settings-form"
              phx-change="validate"
              phx-submit="save"
              class="grid gap-6"
            >
              <.dm_input
                field={@form[:storage_path]}
                label="Storage path"
                errors={@errors}
                helper="Default: gaonote. Use letters, numbers, hyphens, or underscores."
                autocomplete="off"
                required
              />
              <div>
                <.dm_btn native_submit variant="primary">Save settings</.dm_btn>
              </div>
            </.form>
          </.dm_card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp assign_form(socket, path, errors) do
    socket
    |> assign(:form, to_form(%{"storage_path" => path}, as: :gao_note))
    |> assign(:errors, errors)
  end

  defp validation_errors(path) do
    case Schema.validate_section(:gao_note, %{storage_path: path}) do
      {:ok, _config} -> []
      {:error, _reason} -> [@invalid_path]
    end
  end

  defp save_error(:environment_override) do
    "Storage path is controlled by an environment variable. Remove the override to save it in TOML."
  end

  defp save_error(:config_not_loaded) do
    "Could not save GaoNote settings: no active TOML configuration file is available."
  end

  defp save_error(:unsupported_gao_note_toml_format) do
    "Could not save GaoNote settings: use a [gao_note] section with a plain storage_path value in TOML."
  end

  defp save_error(_reason) do
    "Could not save GaoNote settings. Check that the active TOML file is valid and writable."
  end
end
