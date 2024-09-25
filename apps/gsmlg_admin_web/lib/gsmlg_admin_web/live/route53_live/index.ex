defmodule GSMLGAdminWeb.Route53Live.Index do
  use GSMLGAdminWeb, :user_live_view

  alias GSMLG.AWS
  alias GSMLG.AWS.Route53

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, active_menu: "aws")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl Phoenix.LiveView
  def handle_event("next_token", %{"next_records" => next_records}, socket) do
    name = next_records |> Enum.at(0)
    type = next_records |> Enum.at(1)

    {resource_record_sets, next} = Route53.list_resource_record_sets(socket.assigns.hosted_zone_id, name, type)
    # IO.inspect({"next_token", resource_record_sets, next})
    socket = socket
    |> assign(:resource_record_sets, socket.assigns.resource_record_sets ++ resource_record_sets)
    |> assign(:next_token, next)

    {:noreply, socket}
  end

  defp apply_action(socket, :list_zones, _params) do
    socket
    |> assign(:page_title, "Route53 Zones")
    |> apply_hosted_zones()
  end

  defp apply_action(socket, :list_records, %{"id" => id} = _params) do
    socket
    |> assign(:page_title, "Route53 Records")
    |> assign(:hosted_zone_id, id)
    |> apply_resource_record_sets()
  end

  defp apply_hosted_zones(socket) do
    {zones, next} = Route53.list_hosted_zones()

    socket
    |> assign(:hosted_zones, zones)
    |> assign(:next_token, next)
  end

  defp apply_resource_record_sets(socket) do
    {resource_record_sets, next} = Route53.list_resource_record_sets(socket.assigns.hosted_zone_id)

    socket
    |> assign(:resource_record_sets, resource_record_sets)
    |> assign(:next_token, next)
  end
end
