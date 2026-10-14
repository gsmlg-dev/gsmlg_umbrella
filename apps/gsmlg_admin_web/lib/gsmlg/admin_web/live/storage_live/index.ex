defmodule GSMLG.AdminWeb.StorageLive.Index do
  use GSMLG.AdminWeb, :user_live_view

  import GSMLG.AdminWeb.StorageLive.Helpers

  alias GSMLG.SessionProcess.{StorageBrowser, StorageReducer}
  alias GSMLG.Accounts.User
  alias GSMLG.Storage
  alias GSMLG.Storage.Inventory

  @impl true
  def mount(_params, %{"session_id" => session_id}, %{assigns: %{current_user: %User{}}} = socket) do
    socket =
      socket
      |> assign(
        active_menu: "storage_files",
        page_title: "Storage - File Browser",
        session_id: session_id,
        prefix: "",
        search: "",
        page: 1,
        folders: [],
        stats: nil,
        files_result: nil,
        bucket: nil,
        loading: false,
        error: nil,
        refreshed_at: nil,
        backend_id: nil,
        show_upload: false,
        upload_tenant: "",
        upload_type: "attachment"
      )
      |> allow_upload(:files,
        accept: :any,
        max_entries: 10,
        max_file_size: 5 * 1024 * 1024 * 1024
      )
      |> stream_configure(:objects, dom_id: &object_dom_id/1)
      |> stream(:objects, [])

    if connected?(socket) do
      Phoenix.PubSub.subscribe(GSMLG.PubSub, "storage:config")

      with {:ok, _ref} <- StorageBrowser.subscribe(session_id),
           :ok <- StorageBrowser.refresh(session_id) do
        {:ok, project_snapshot(socket, StorageBrowser.snapshot(session_id))}
      else
        {:error, _reason} -> {:ok, session_error(socket)}
      end
    else
      {:ok, project_snapshot(socket, StorageBrowser.snapshot(session_id))}
    end
  end

  def mount(_params, _session, socket), do: {:ok, redirect(socket, to: "/sign_in")}

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> assign(
        prefix: params["prefix"] || "",
        search: params["search"] || "",
        page: parse_page(params["page"])
      )
      |> project_snapshot(StorageBrowser.snapshot(socket.assigns.session_id))

    {:noreply, socket}
  end

  @impl true
  def handle_info({:storage_snapshot, snapshot}, socket) do
    if snapshot.backend_id == Inventory.current_backend_id() do
      {:noreply, project_snapshot(socket, snapshot)}
    else
      {:noreply, refresh(socket)}
    end
  end

  def handle_info({:storage_backend_changed, _id}, socket),
    do: {:noreply, refresh(socket)}

  @impl true
  def handle_event(_event, _params, %{assigns: %{current_user: user}} = socket)
      when not is_struct(user, User),
      do: {:noreply, redirect(socket, to: "/sign_in")}

  def handle_event("refresh", _params, %{assigns: %{current_user: %User{}}} = socket),
    do: {:noreply, refresh(socket)}

  def handle_event("refresh", _params, socket),
    do: {:noreply, redirect(socket, to: "/sign_in")}

  def handle_event("search", %{"search" => search}, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/storage?#{filter_params(socket.assigns, search: search, page: 1)}"
     )}
  end

  def handle_event("delete", %{"key" => encoded, "backend" => expected}, socket) do
    with :ok <- check_backend(socket, expected),
         {:ok, key} <- Inventory.decode_key(encoded),
         {:ok, _} <- Storage.delete_object(key, expected) do
      {:noreply, socket |> put_flash(:info, "File deleted") |> refresh()}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, mutation_error(reason))}
    end
  end

  def handle_event("create_folder", %{"folder" => folder, "backend" => expected}, socket) do
    with :ok <- check_backend(socket, expected),
         {:ok, _} <- Storage.create_object_folder(socket.assigns.prefix <> folder, expected) do
      {:noreply, socket |> put_flash(:info, "Folder created") |> refresh()}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, mutation_error(reason))}
    end
  end

  def handle_event("toggle_upload", _params, socket),
    do: {:noreply, assign(socket, show_upload: !socket.assigns.show_upload)}

  def handle_event("validate_upload", %{"tenant" => tenant, "type" => type}, socket),
    do: {:noreply, assign(socket, upload_tenant: tenant, upload_type: type)}

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :files, ref)}

  def handle_event(
        "save_upload",
        %{"tenant" => tenant, "type" => type, "backend" => expected},
        socket
      ) do
    with :ok <- check_backend(socket, expected) do
      results =
        consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
          input = %Plug.Upload{
            path: path,
            filename: entry.client_name,
            content_type: entry.client_type
          }

          case Storage.upload(input, String.trim(tenant), String.trim(type),
                 backend_id: expected,
                 uploaded_by: "admin",
                 metadata: %{original_name: entry.client_name}
               ) do
            {:ok, file} -> {:ok, file}
            {:error, reason} -> {:postpone, reason}
          end
        end)

      count = Enum.count(results, &match?(%GSMLG.Storage.StorageFile{}, &1))

      if count > 0 do
        {:noreply,
         socket
         |> assign(show_upload: false)
         |> put_flash(:info, "#{count} file(s) uploaded")
         |> refresh()}
      else
        {:noreply,
         put_flash(
           socket,
           :error,
           "Upload failed. Check the tenant and file type, then try again."
         )}
      end
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, mutation_error(reason))}
    end
  end

  def handle_event(_event, _params, socket),
    do: {:noreply, put_flash(socket, :error, "Refresh the listing before changing files.")}

  defp check_backend(socket, expected) do
    if is_binary(expected) and expected == socket.assigns.backend_id and
         expected == Inventory.current_backend_id(),
       do: :ok,
       else: {:error, :backend_changed}
  end

  defp refresh(socket) do
    case StorageBrowser.refresh(socket.assigns.session_id) do
      :ok -> project_snapshot(socket, StorageBrowser.snapshot(socket.assigns.session_id))
      {:error, _reason} -> session_error(socket)
    end
  end

  defp project_snapshot(socket, {:error, _reason}), do: session_error(socket)

  defp project_snapshot(socket, snapshot) do
    snapshot =
      if snapshot.backend_id == Inventory.current_backend_id(),
        do: snapshot,
        else: StorageReducer.init_state()

    result =
      Inventory.project(snapshot.objects,
        prefix: socket.assigns.prefix,
        search: socket.assigns.search,
        page: socket.assigns.page
      )

    socket
    |> assign(
      files_result: Map.drop(result, [:objects, :folders, :stats]),
      folders: result.folders,
      stats: result.stats,
      page: result.page,
      bucket: snapshot.bucket,
      backend_id: snapshot.backend_id,
      loading: snapshot.loading,
      error: snapshot.error,
      refreshed_at: snapshot.refreshed_at
    )
    |> stream(:objects, result.objects, reset: true)
  end

  defp session_error(socket),
    do: assign(socket, loading: false, error: :session_not_found)

  defp filter_params(assigns, overrides) do
    %{
      prefix: Keyword.get(overrides, :prefix, assigns.prefix),
      search: Keyword.get(overrides, :search, assigns.search),
      page: Keyword.get(overrides, :page, assigns.page)
    }
    |> Enum.reject(fn
      {:page, 1} -> true
      {_key, value} -> value in [nil, ""]
    end)
  end

  defp object_dom_id(object), do: "s3-object-" <> Inventory.encode_key(object.key)

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page > 0 -> page
      _ -> 1
    end
  end

  defp parse_page(_value), do: 1
end
