defmodule GSMLGAdminWeb.UserLive.Index do
  use GSMLGAdminWeb, :user_live_view

  alias GSMLG.Accounts
  alias GSMLG.Accounts.User

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, users: [], active_menu: "user_list")}
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

  defp apply_action(socket, :new, _params) do
    user = %User{}
    changeset = Accounts.change_user(user)

    socket
    |> assign(:page_title, "New User")
    |> assign(:changeset, changeset)
    |> assign(:user, user)
  end

  defp apply_action(socket, :edit, %{"id" => id} = _params) do
    user = Accounts.get_user!(id)
    changeset = Accounts.change_user(user)

    socket
    |> assign(:page_title, "Edit User")
    |> assign(:changeset, changeset)
    |> assign(:user, user)
  end

  defp apply_action(socket, :show, %{"id" => id} = _params) do
    socket
    |> assign(:page_title, "Show User")
    |> assign(:user, Accounts.get_user!(id))
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)
    {:ok, _} = Accounts.delete_user(user)

    {:noreply, socket |> apply_users()}
  end

  def handle_event("save", %{"user" => user_params}, socket) do
    user = socket.assigns.user

    case Accounts.update_user(user, user_params) do
      {:ok, _user} ->
        {:noreply, socket |> redirect(to: ~p"/users")}

      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  defp apply_users(socket) do
    socket
    |> assign(:users, Accounts.list_users())
  end
end
