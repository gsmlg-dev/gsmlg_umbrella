defmodule GSMLG.AdminWeb.StorageLive.Show do
  use GSMLG.AdminWeb, :user_live_view

  import GSMLG.AdminWeb.StorageLive.Helpers

  alias GSMLG.Accounts.User
  alias GSMLG.Storage
  alias GSMLG.Storage.{Catalog, Inventory, S3Client}

  @impl true
  def mount(
        %{"id" => encoded, "backend" => expected},
        _session,
        %{assigns: %{current_user: %User{}}} = socket
      ) do
    with {:ok, key} <- Inventory.decode_key(encoded),
         true <- String.valid?(key),
         false <- Catalog.internal_key?(key),
         {:ok, backend} <- Inventory.backend(),
         true <- backend.id == expected,
         {:ok, object} <- S3Client.head_object(backend, key),
         managed <- managed_file(key, backend),
         true <- backend.id == Inventory.current_backend_id() do
      if connected?(socket), do: Phoenix.PubSub.subscribe(GSMLG.PubSub, "storage:config")

      {:ok,
       assign(socket,
         object: object,
         managed_file: managed,
         backend_id: backend.id,
         bucket: backend.bucket,
         active_menu: "storage_files",
         page_title: "Storage - #{key}"
       )}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(
           :error,
           "File unavailable or S3 configuration changed. Refresh the listing."
         )
         |> push_navigate(to: ~p"/storage")}
    end
  end

  def mount(_params, _session, %{assigns: %{current_user: %User{}}} = socket),
    do:
      {:ok,
       socket
       |> put_flash(:error, "Open a file from the current S3 listing.")
       |> push_navigate(to: ~p"/storage")}

  def mount(_params, _session, socket), do: {:ok, redirect(socket, to: "/sign_in")}

  @impl true
  def handle_info({:storage_backend_changed, _id}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, storage_error(:backend_changed))
     |> push_navigate(to: ~p"/storage")}
  end

  @impl true
  def handle_event(_event, _params, %{assigns: %{current_user: user}} = socket)
      when not is_struct(user, User),
      do: {:noreply, redirect(socket, to: "/sign_in")}

  def handle_event("delete", %{"backend" => expected}, socket) do
    result =
      if expected == socket.assigns.backend_id,
        do: Storage.delete_object(socket.assigns.object.key, expected),
        else: {:error, :backend_changed}

    case result do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "File deleted") |> push_navigate(to: ~p"/storage")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, mutation_error(reason))}
    end
  end

  def handle_event("regenerate_variants", %{"backend" => expected}, socket) do
    if expected == socket.assigns.backend_id and expected == Inventory.current_backend_id() and
         socket.assigns.managed_file do
      case Storage.regenerate_variants(socket.assigns.managed_file) do
        :ok -> {:noreply, put_flash(socket, :info, "Variant regeneration started")}
        {:error, reason} -> {:noreply, put_flash(socket, :error, mutation_error(reason))}
      end
    else
      {:noreply, put_flash(socket, :error, mutation_error(:backend_changed))}
    end
  end

  def handle_event(_event, _params, socket),
    do: {:noreply, put_flash(socket, :error, "Refresh the listing before changing files.")}

  defp managed_file(key, backend) do
    case Catalog.list(backend: backend, status: "active") do
      {:ok, files} -> Enum.find(files, &(&1.s3_key == key))
      {:error, _} -> nil
    end
  end
end
