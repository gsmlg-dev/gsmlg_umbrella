defmodule GSMLGWeb.UserTokenLive.FormComponent do
  use GSMLGWeb, :live_component

  alias GSMLG.Accounts

  @impl true
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
      socket.assigns.user_token
      |> Accounts.change_user_token(user_token_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("save", %{"user_token" => user_token_params}, socket) do
    save_user_token(socket, socket.assigns.action, user_token_params)
  end

  defp save_user_token(socket, :edit, user_token_params) do
    case Accounts.update_user_token(socket.assigns.user_token, user_token_params) do
      {:ok, _user_token} ->
        {:noreply,
         socket
         |> put_flash(:info, "User token updated successfully")
         |> push_redirect(to: socket.assigns.return_to)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  defp save_user_token(socket, :new, user_token_params) do
    case Accounts.create_user_token(user_token_params) do
      {:ok, _user_token} ->
        {:noreply,
         socket
         |> put_flash(:info, "User token created successfully")
         |> push_redirect(to: socket.assigns.return_to)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end
end
