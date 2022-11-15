defmodule GSMLGAdminWeb.UserLive.Index do
  use GSMLGAdminWeb, :live_view

  alias GSMLG.Accounts
  # alias GSMLG.Accounts.User

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :users, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Users")
    |> apply_users()
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)
    {:ok, _} = Accounts.delete_user(user)

    {:noreply, socket |> apply_users()}
  end

  defp apply_users(socket) do
    socket
    |> assign(:users, Accounts.list_users())
  end
end
