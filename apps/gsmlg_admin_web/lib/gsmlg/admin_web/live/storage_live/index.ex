defmodule GSMLG.AdminWeb.StorageLive.Index do
  use GSMLG.AdminWeb, :user_live_view

  import GSMLG.AdminWeb.StorageLive.Helpers

  alias GSMLG.Storage

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(active_menu: "storage_files")
     |> assign(
       tenant_filter: nil,
       type_filter: nil,
       search: nil,
       page: 1,
       year_filter: nil,
       month_filter: nil
     )
     |> assign(stats: nil, files_result: nil, tree: nil)
     |> assign(folder_modal: nil, folder_form: nil)
     |> stream(:files, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    page = parse_int(params["page"], 1)
    tenant = params["tenant"]
    type = params["type"]
    search = params["search"]
    year = parse_int(params["year"], nil)
    month = parse_int(params["month"], nil)

    socket =
      socket
      |> assign(
        page: page,
        tenant_filter: tenant,
        type_filter: type,
        search: search,
        year_filter: year,
        month_filter: month
      )
      |> assign(page_title: "Storage - File Browser")
      |> start_async(:load_files, fn ->
        files =
          Storage.list(
            tenant: tenant,
            type: type,
            search: search,
            page: page,
            year: year,
            month: month
          )

        stats = Storage.stats(tenant)
        tree = Storage.folder_tree()
        {files, stats, tree}
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_async(:load_files, {:ok, {files_result, stats, tree}}, socket) do
    {:noreply,
     socket
     |> assign(files_result: files_result, stats: stats, tree: tree)
     |> stream(:files, files_result.files, reset: true)}
  end

  def handle_async(:load_files, {:exit, _reason}, socket) do
    {:noreply,
     assign(socket,
       files_result: %{files: [], total: 0, page: 1, page_size: 20, total_pages: 0},
       stats: nil,
       tree: []
     )}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    params = build_filter_params(socket.assigns, search: search, page: 1)
    {:noreply, push_patch(socket, to: ~p"/storage?#{params}")}
  end

  def handle_event("filter", %{"tenant" => tenant, "type" => type}, socket) do
    params = build_filter_params(socket.assigns, tenant: tenant, type: type, page: 1)
    {:noreply, push_patch(socket, to: ~p"/storage?#{params}")}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Storage.delete(id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "File deleted")
         |> push_patch(to: ~p"/storage?#{build_filter_params(socket.assigns, [])}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete file")}
    end
  end

  # --- Folder modal events ---

  def handle_event("show_create_folder_modal", %{"level" => "root"}, socket) do
    {:noreply, assign(socket, folder_modal: :root, folder_form: %{tenant: "", type: ""})}
  end

  def handle_event("show_create_folder_modal", %{"level" => "tenant", "tenant" => tenant}, socket) do
    {:noreply, assign(socket, folder_modal: :tenant, folder_form: %{tenant: tenant, type: ""})}
  end

  def handle_event("close_folder_modal", _params, socket) do
    {:noreply, assign(socket, folder_modal: nil, folder_form: nil)}
  end

  def handle_event("create_folder", %{"tenant" => tenant, "type" => type}, socket) do
    tenant = String.trim(tenant)
    type = if String.trim(type) == "", do: nil, else: String.trim(type)

    case Storage.create_folder(tenant, type) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(folder_modal: nil, folder_form: nil)
         |> put_flash(:info, "Folder created")
         |> push_patch(to: ~p"/storage?#{build_filter_params(socket.assigns, [])}")}

      {:error, changeset} ->
        errors = changeset.errors
        error_msg = Enum.map_join(errors, ", ", fn {field, {msg, _}} -> "#{field} #{msg}" end)
        {:noreply, assign(socket, folder_form: %{tenant: tenant, type: type || "", error: error_msg})}
    end
  end

  def handle_event(
        "delete_folder",
        %{"tenant" => tenant} = params,
        socket
      ) do
    type = params["type"]
    year = parse_int(params["year"], nil)
    month = parse_int(params["month"], nil)

    case Storage.delete_folder(tenant, type, year, month) do
      {:ok, _} ->
        nav_params =
          case {type, year} do
            {nil, _} -> %{}
            {_, nil} -> %{tenant: tenant}
            _ -> %{tenant: tenant, type: type}
          end

        {:noreply,
         socket
         |> put_flash(:info, "Folder deleted")
         |> push_patch(to: ~p"/storage?#{nav_params}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete folder")}
    end
  end

  defp build_filter_params(assigns, overrides) do
    %{
      tenant: Keyword.get(overrides, :tenant, assigns.tenant_filter),
      type: Keyword.get(overrides, :type, assigns.type_filter),
      search: Keyword.get(overrides, :search, assigns.search),
      year: Keyword.get(overrides, :year, assigns.year_filter),
      month: Keyword.get(overrides, :month, assigns.month_filter),
      page: Keyword.get(overrides, :page, assigns.page)
    }
    |> Enum.reject(fn
      {:page, 1} -> true
      {_k, v} -> is_nil(v) or v == ""
    end)
  end

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default

  defp parse_int(str, default) do
    case Integer.parse(str) do
      {n, ""} -> n
      _ -> default
    end
  end
end
