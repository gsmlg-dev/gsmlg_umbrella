defmodule GSMLG.AdminWeb.UserLive.Index do
  use GSMLG.AdminWeb, :user_live_view

  alias Phoenix.SessionProcess
  alias GSMLG.Accounts
  alias GSMLG.Accounts.User

  @impl true
  def mount(_params, %{"session_id" => session_id} = _session, socket) do
    Process.flag(:trap_exit, true)

    {:ok, _sub_id} =
      SessionProcess.subscribe(
        session_id,
        fn state ->
          get_in(state, [:user, :users])
        end,
        :list_users,
        self()
      )

    {:ok, assign(socket, users: [], active_menu: "user_list", session_id: session_id)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    SessionProcess.dispatch(socket.assigns.session_id, "list_users")

    socket
    |> assign(:page_title, "Listing Users")
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
    SessionProcess.dispatch(socket.assigns.session_id, "remove-user", %{user_id: id})

    {:noreply, socket}
  end

  def handle_event("save", %{"user" => user_params}, socket) do
    user = socket.assigns.user

    case Accounts.update_user(user, user_params) do
      {:ok, _user} ->
        SessionProcess.dispatch(socket.assigns.session_id, "list_users")

        {:noreply, socket |> redirect(to: ~p"/users")}

      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  @impl true
  def handle_info({:list_users, users}, socket) do
    {:noreply, socket |> assign(:users, users)}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state) do
    IO.inspect({:user_view_stopped, state})
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, pid, {:shutdown, reason}}, state) do
    IO.inspect({:live_view, :DOWN, ref, :process, pid, {:shutdown, reason}})
    {:noreply, state}
  end
end
