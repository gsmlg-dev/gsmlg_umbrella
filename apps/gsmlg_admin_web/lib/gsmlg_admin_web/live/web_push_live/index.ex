defmodule GSMLGAdminWeb.WebPushLive.Index do
  use GSMLGAdminWeb, :user_live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, web_push: [], active_menu: "web_push_list")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, page_title(socket.assigns.live_action))
    |> assign(:web_push, GSMLG.WebPush.Subscriptions.get_subscriptions())
  end

  @impl true
  def handle_event("delete", %{"endpoint" => endpoint}, socket) do
    GSMLG.WebPush.Subscriptions.remove(endpoint)
    {:noreply, socket |> assign(:web_push, GSMLG.WebPush.Subscriptions.get_subscriptions())}
  end

  def handle_event(
        "web_push_to_endpoint",
        %{"title" => title, "content" => content, "endpoint" => endpoint},
        socket
      ) do
    subscription = GSMLG.WebPush.Subscriptions.get(endpoint)

    GSMLG.WebPush.send(subscription, %{title: title, body: content})

    {:noreply, socket}
  end

  def handle_event(
        "web_push_broadcast",
        %{"title" => title, "content" => content},
        socket
      ) do
    GSMLG.WebPush.Subscriptions.get_subscriptions()
    |> Enum.each(fn subscription ->
      GSMLG.WebPush.send(subscription, %{title: title, body: content})
      |> IO.inspect(label: "Web Push Result")
    end)

    {:noreply, socket}
  end

  defp page_title(:index), do: "Listing Web PUsh Subscriptions"
end
