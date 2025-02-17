defmodule GSMLGAdminWeb.DynamoDBLive.Index do
  use GSMLGAdminWeb, :aws_live_view

  alias GSMLG.AWS.DynamoDB

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:active_menu, "dynamo_db")

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_event("describe_table", %{"table" => name}, socket) do
    socket =
      socket
      |> assign_async([:table], fn ->
        case DynamoDB.describe_table(name) do
          {:ok, %{"Table" => table}, _resp} ->
            {:ok, %{table: table}}

          {:error, reason} ->
            {:error, reason}
        end
      end)
    {:noreply, socket}
  end

  def handle_event("delete_record", %{"record" => rr}, socket) do
    {:noreply, socket}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "AWS DynamoDB")
    |> assign_async([:tables], fn ->
      case GSMLG.AWS.DynamoDB.list_tables() do
        {:ok, %{"TableNames" => tables}, _resp} ->
          {:ok, %{tables: tables}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp apply_action(socket, :list_zones, _params) do
    socket
    |> assign(:page_title, "AWS DynamoDB")
  end

  defp apply_action(socket, :list_records, %{"id" => id} = _params) do
    socket
    |> assign(:page_title, "AWS DynamoDB")
    |> assign(:hosted_zone_id, id)
  end
end
