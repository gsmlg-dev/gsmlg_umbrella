defmodule GSMLGAdminWeb.UserTokenLive.Index do
  use GSMLGAdminWeb, :user_live_view

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

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, page_title(socket.assigns.live_action))
    |> assign(:user_tokens, Accounts.list_user_tokens())
  end

  defp apply_action(socket, :new, _params) do
    changeset = Accounts.change_user_token(%UserToken{})

    socket
    |> assign(:page_title, page_title(socket.assigns.live_action))
    |> assign(:changeset, changeset)
    |> assign(:user_token, %UserToken{})
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    user_token = Accounts.get_user_token!(id)
    changeset = Accounts.change_user_token(user_token)

    socket
    |> assign(:page_title, page_title(socket.assigns.live_action))
    |> assign(:changeset, changeset)
    |> assign(:user_token, user_token)
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    socket
    |> assign(:page_title, page_title(socket.assigns.live_action))
    |> assign(:user_token, Accounts.get_user_token!(id))
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    user_token = Accounts.get_user_token!(id)
    {:ok, _} = Accounts.delete_user_token(user_token)

    {:noreply,
     socket
     |> assign(:user_tokens, Accounts.list_user_tokens())}
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"user_token" => user_token_params}, socket) do
    changeset =
      socket.assigns.user
      |> Accounts.change_user_token(user_token_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  @impl Phoenix.LiveView
  def handle_event("save", %{"user_token" => user_token_params}, socket) do
    save_user_token(socket, socket.assigns.live_action, user_token_params)
  end

  defp save_user_token(socket, :edit, user_token_params) do
    case Accounts.update_user_token(socket.assigns.user_token, user_token_params) do
      {:ok, user_token} ->
        {:noreply,
         socket
         |> put_flash(:info, "User Token updated successfully")
         |> push_navigate(to: ~p"/user_tokens/#{user_token.jti}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  defp save_user_token(socket, :new, user_token_params) do
    case Accounts.create_user_token(user_token_params) do
      {:ok, user_token} ->
        {:noreply,
         socket
         |> put_flash(:info, "User Token created successfully")
         |> push_navigate(to: ~p"/user_tokens/#{user_token.jti}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  defp page_title(:index), do: "Listing User tokens"
  defp page_title(:new), do: "New User Token"
  defp page_title(:show), do: "Show User token"
  defp page_title(:edit), do: "Edit User token"
end
