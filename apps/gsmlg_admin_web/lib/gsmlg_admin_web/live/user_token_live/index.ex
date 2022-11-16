defmodule GSMLGAdminWeb.UserTokenLive.Index do
  use GSMLGAdminWeb, :live_view

  alias GSMLG.Accounts
  alias GSMLG.Accounts.UserToken

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, user_tokens: [], active_menu: "user_token_list")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit User token")
    |> assign(:user_token, Accounts.get_user_token!(id))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New User token")
    |> assign(:user_token, %UserToken{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing User tokens")
    |> apply_user_tokens()
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    user_token = Accounts.get_user_token!(id)
    {:ok, _} = Accounts.delete_user_token(user_token)

    {:noreply, socket |> apply_user_tokens()}
  end

  defp apply_user_tokens(socket) do
    socket
    |> assign(:user_tokens, Accounts.list_user_tokens())
  end
end
