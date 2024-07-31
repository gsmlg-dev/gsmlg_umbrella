defmodule GSMLGAdminWeb.BlogLive.Index do
  use GSMLGAdminWeb, :user_live_view

  alias GSMLG.Content

  @impl true
  def mount(_params, _session, socket) do
    Process.send_after(__MODULE__, :refresh_list, 15_000)

    socket =
      socket
      |> stream(:blogs, [])
      |> start_async(:get_blogs, fn -> Content.list_blogs() end)

    {:ok, assign(socket, active_menu: "blog_list")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Blogs")

    # |> apply_blogs()
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    blog = Content.get_blog!(id)
    {:ok, _} = Content.delete_blog(blog)

    {:noreply, socket |> apply_blogs()}
  end

  @impl true
  def handle_info(:refresh_list, socket) do
    Process.send_after(__MODULE__, :refresh_list, 15_000)
    {:noreply, socket |> apply_blogs()}
  end

  def handle_async(:get_blogs, {:ok, fetched_blogs}, socket) do
    {:noreply, stream(socket, :blogs, fetched_blogs)}
  end

  defp apply_blogs(socket) do
    socket
    |> assign(:blogs, Content.list_blogs())
  end
end
