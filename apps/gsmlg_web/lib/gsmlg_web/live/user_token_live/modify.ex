defmodule GSMLGWeb.UserTokenLive.Modify do
  use GSMLGWeb, :live_view

  alias GSMLG.Accounts
  alias GSMLG.Accounts.UserToken

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    user_token = Accounts.get_user_token!(id)
    changeset = Accounts.change_user_token(user_token)

    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:changeset, changeset)
     |> assign(:user_token, user_token)}
  end

  @impl true
  def handle_params(_, _, socket) do
    changeset = Accounts.change_user_token(%UserToken{})

    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:changeset, changeset)
     |> assign(:user_token, %UserToken{})}
  end

  defp page_title(:new), do: "New User Token"
  defp page_title(:edit), do: "Edit User Token"

  def update(%{user_token: user_token} = assigns, socket) do
    changeset = Accounts.change_user_token(user_token)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, changeset)}
  end

  @impl true
  def handle_event("validate", %{"user_token" => user_token_params}, socket) do
    changeset =
      socket.assigns.user
      |> Accounts.change_user_token(user_token_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("save", %{"user_token" => user_token_params}, socket) do
    save_user_token(socket, socket.assigns.live_action, user_token_params)
  end

  defp save_user_token(socket, :edit, user_token_params) do
    case Accounts.update_user_token(socket.assigns.user_token, user_token_params) do
      {:ok, user_token} ->
        {:noreply,
         socket
         |> put_flash(:info, "User Token updated successfully")
         |> push_redirect(to: ~p"/admin/user_tokens/#{user_token.jti}")}

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
         |> push_redirect(to: ~p"/admin/user_tokens/#{user_token.jti}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end
end
