defmodule GSMLG.AdminWeb.StorageLive.Index do
  use GSMLG.AdminWeb, :user_live_view

  import GSMLG.AdminWeb.StorageLive.Helpers

  alias GSMLG.Storage

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(active_menu: "storage_files")
     |> assign(tenant_filter: nil, type_filter: nil, search: nil, page: 1)
     |> assign(stats: nil, files_result: nil)
     |> stream(:files, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    page = String.to_integer(params["page"] || "1")
    tenant = params["tenant"]
    type = params["type"]
    search = params["search"]

    socket =
      socket
      |> assign(page: page, tenant_filter: tenant, type_filter: type, search: search)
      |> assign(page_title: "Storage - File Browser")
      |> start_async(:load_files, fn ->
        files = Storage.list(tenant: tenant, type: type, search: search, page: page)
        stats = Storage.stats(tenant)
        {files, stats}
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_async(:load_files, {:ok, {files_result, stats}}, socket) do
    {:noreply,
     socket
     |> assign(files_result: files_result, stats: stats)
     |> stream(:files, files_result.files, reset: true)}
  end

  def handle_async(:load_files, {:exit, _reason}, socket) do
    {:noreply,
     assign(socket,
       files_result: %{files: [], total: 0, page: 1, page_size: 20, total_pages: 0},
       stats: nil
     )}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    params = build_filter_params(socket.assigns, search: search)
    {:noreply, push_patch(socket, to: ~p"/storage?#{params}")}
  end

  def handle_event("filter", %{"tenant" => tenant, "type" => type}, socket) do
    params = build_filter_params(socket.assigns, tenant: tenant, type: type)
    {:noreply, push_patch(socket, to: ~p"/storage?#{params}")}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Storage.delete(id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "File deleted")
         |> push_patch(to: ~p"/storage")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete file")}
    end
  end

  defp build_filter_params(assigns, overrides) do
    %{
      tenant: Keyword.get(overrides, :tenant, assigns.tenant_filter),
      type: Keyword.get(overrides, :type, assigns.type_filter),
      search: Keyword.get(overrides, :search, assigns.search)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
  end
end
