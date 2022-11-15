defmodule GSMLGAdminWeb.UserTokenLive.Show do
  use GSMLGAdminWeb, :live_view

  alias GSMLG.Accounts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:user_token, Accounts.get_user_token!(id))}
  end

  defp page_title(:show), do: "Show User token"
  defp page_title(:edit), do: "Edit User token"
end
