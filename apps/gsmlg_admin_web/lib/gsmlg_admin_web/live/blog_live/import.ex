defmodule GSMLGAdminWeb.BlogLive.Import do
  use GSMLGAdminWeb, :user_live_view

  # alias GSMLG.Content
  alias GSMLG.Content.BlogImport

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, active_menu: "blog_import")}
  end

  @impl true
  def handle_params(_, _, socket) do
    changeset = BlogImport.changeset(%BlogImport{}, %{})

    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:changeset, changeset)}
  end

  defp page_title(:import), do: "Import Blog"

  @impl true
  def handle_event("validate", %{"blog_import" => import_params}, socket) do
    changeset =
      BlogImport.changeset(%BlogImport{}, import_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("save", %{"blog_import" => import_params}, socket) do
    import_blog(socket, import_params)
  end

  defp import_blog(socket, import_params) do
    case BlogImport.import(import_params) do
      {:ok, _blog} ->
        {:noreply,
         socket
         |> put_flash(:info, "Blog import successfully")
         |> push_navigate(to: ~p"/blogs")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end
end
