defmodule GSMLG.AdminWeb.StorageLive.Upload do
  use GSMLG.AdminWeb, :user_live_view

  import GSMLG.AdminWeb.StorageLive.Helpers

  alias GSMLG.Storage

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(active_menu: "storage_upload")
     |> assign(page_title: "Storage - Upload")
     |> assign(tenant: "default", type: "attachment", uploaded_files: [])
     |> allow_upload(:files,
       accept: :any,
       max_entries: 10,
       max_file_size: 5 * 1024 * 1024 * 1024,
       auto_upload: false
     )}
  end

  @impl true
  def handle_event("validate", %{"tenant" => tenant, "type" => type}, socket) do
    {:noreply, assign(socket, tenant: tenant, type: type)}
  end

  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("upload", _params, socket) do
    tenant = socket.assigns.tenant
    type = socket.assigns.type
    current_user = socket.assigns[:current_user]
    uploaded_by = if current_user, do: current_user.username || current_user.email, else: "admin"

    uploaded_files =
      consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
        case Storage.upload(
               path,
               tenant,
               type,
               uploaded_by: uploaded_by,
               metadata: %{"original_name" => entry.client_name}
             ) do
          {:ok, file} -> {:ok, file}
          {:error, reason} -> {:postpone, {:error, entry.client_name, reason}}
        end
      end)

    successes = Enum.filter(uploaded_files, &match?(%GSMLG.Storage.StorageFile{}, &1))
    errors = Enum.filter(uploaded_files, &match?({:error, _, _}, &1))

    socket =
      socket
      |> assign(uploaded_files: successes)
      |> then(fn s ->
        if length(successes) > 0,
          do: put_flash(s, :info, "#{length(successes)} file(s) uploaded successfully"),
          else: s
      end)
      |> then(fn s ->
        if length(errors) > 0,
          do: put_flash(s, :error, "#{length(errors)} file(s) failed to upload"),
          else: s
      end)

    {:noreply, socket}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :files, ref)}
  end
end
