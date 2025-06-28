defmodule GSMLGAdminWeb.S3Live.Index do
  use GSMLGAdminWeb, :aws_live_view

  alias GSMLG.AWS.S3

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:active_menu, "s3_buckets_list")
      |> assign(:buckets, %Phoenix.LiveView.AsyncResult{ok?: false, loading: true})

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :list_buckets, _params) do
    socket
    |> assign(:page_title, "AWS S3")
    |> apply_buckets()
  end

  defp apply_buckets(socket) do
    socket
    |> assign_async([:buckets], fn ->
      buckets = S3.list_buckets()
      {:ok, %{buckets: %{list: buckets}}}
    end)
  end

end
