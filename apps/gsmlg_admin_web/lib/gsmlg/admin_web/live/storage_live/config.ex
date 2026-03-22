defmodule GSMLG.AdminWeb.StorageLive.Config do
  use GSMLG.AdminWeb, :user_live_view

  alias GSMLG.Storage
  alias GSMLG.Storage.StorageConfig

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Storage — S3 Configuration")
     |> assign(active_menu: "storage_config")
     |> assign_form()}
  end

  @impl true
  def handle_event("validate", %{"storage_config" => params}, socket) do
    changeset =
      socket.assigns.config
      |> StorageConfig.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: :storage_config))}
  end

  def handle_event("save", %{"storage_config" => params}, socket) do
    case Storage.update_config(params) do
      {:ok, _config} ->
        {:noreply,
         socket
         |> put_flash(:info, "S3 configuration saved.")
         |> assign_form()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :storage_config))}
    end
  end

  defp assign_form(socket) do
    config = Storage.get_config()

    changeset = StorageConfig.changeset(config, %{})

    socket
    |> assign(config: config)
    |> assign(form: to_form(changeset, as: :storage_config))
  end
end
