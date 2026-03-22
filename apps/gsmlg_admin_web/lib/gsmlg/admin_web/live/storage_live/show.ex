defmodule GSMLG.AdminWeb.StorageLive.Show do
  use GSMLG.AdminWeb, :user_live_view

  import GSMLG.AdminWeb.StorageLive.Helpers

  alias GSMLG.Storage

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Storage.get(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "File not found")
         |> push_navigate(to: ~p"/storage")}

      file ->
        {:ok,
         socket
         |> assign(file: file)
         |> assign(active_menu: "storage_files")
         |> assign(page_title: "Storage - #{file.filename}")}
    end
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case Storage.delete(socket.assigns.file) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "File deleted")
         |> push_navigate(to: ~p"/storage")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete file")}
    end
  end

  def handle_event("regenerate_variants", _params, socket) do
    case Storage.regenerate_variants(socket.assigns.file) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Variant regeneration started")}

      {:error, :not_an_image} ->
        {:noreply, put_flash(socket, :error, "Not an image file")}
    end
  end

  def handle_event("copy_url", _params, socket) do
    {:noreply, put_flash(socket, :info, "URL copied to clipboard")}
  end
end
