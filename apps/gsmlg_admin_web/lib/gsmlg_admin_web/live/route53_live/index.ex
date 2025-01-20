defmodule GSMLGAdminWeb.Route53Live.Index do
  use GSMLGAdminWeb, :aws_live_view

  alias GSMLG.AWS.Route53

  @impl true
  def mount(_params, _session, socket) do
    socket = socket
      |> assign(:active_menu, "route53_hosted_zone_list")
      |> assign(:resource_record_sets, %Phoenix.LiveView.AsyncResult{ok?: false, loading: true})
    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl Phoenix.LiveView
  def handle_event("next_token", %{"next_records" => next_records}, socket) do
    name = next_records |> Enum.at(0)
    type = next_records |> Enum.at(1)
    hosted_zone_id = socket.assigns.hosted_zone_id
    old_resource_record_sets = socket.assigns.resource_record_sets.result.list

    socket =
      socket
      |> assign_async([:resource_record_sets], fn ->
        {resource_record_sets, next} =
          Route53.list_resource_record_sets(hosted_zone_id, name, type)

        {:ok,
         %{
           resource_record_sets: %{
             list: old_resource_record_sets ++ resource_record_sets,
             next_token: next
           }
         }}
      end)

    {:noreply, socket}
  end

  def handle_event("delete_record", %{"record" => rr}, socket) do
    hosted_zone_id = socket.assigns.hosted_zone_id
    old_resource_record_sets = socket.assigns.resource_record_sets.result.list

    socket =
      socket
      |> assign_async([:resource_record_sets], fn ->
        req_input = %{
          {"ChangeResourceRecordSetsRequest",
           %{xmlns: "https://route53.amazonaws.com/doc/2013-04-01/"}} => %{
            "ChangeBatch" => %{
              "Comment" => "Delete single record set",
              "Changes" => [
                %{
                  "Change" => %{
                    "Action" => "DELETE",
                    "ResourceRecordSet" => rr
                  }
                }
              ]
            }
          }
        }

        :ok = Route53.change_resource_record_sets(hosted_zone_id, req_input)
        resource_record_sets = old_resource_record_sets |> Enum.reject(fn r -> r == rr end)
        {:ok, %{resource_record_sets: %{list: resource_record_sets, next_token: nil}}}
      end)

    {:noreply, socket}
  end

  defp apply_action(socket, :list_zones, _params) do
    socket
    |> assign(:page_title, "AWS Route53")
    |> apply_hosted_zones()
  end

  defp apply_action(socket, :list_records, %{"id" => id} = _params) do
    socket
    |> assign(:page_title, "AWS Route53")
    |> assign(:hosted_zone_id, id)
    |> apply_resource_record_sets()
  end

  defp apply_hosted_zones(socket) do
    socket
    |> assign_async([:hosted_zones], fn ->
      {zones, next} = Route53.list_hosted_zones()
      {:ok, %{hosted_zones: %{list: zones, next_token: next}}}
    end)
  end

  defp apply_resource_record_sets(socket) do
    hosted_zone_id = socket.assigns.hosted_zone_id

    socket
    |> assign_async([:resource_record_sets], fn ->
      {resource_record_sets, next} =
        Route53.list_resource_record_sets(hosted_zone_id)

      {:ok, %{resource_record_sets: %{ hosted_zone_id => %{list: resource_record_sets, next_token: next}}}}
    end)
  end
end
