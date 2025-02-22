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

  def handle_event("list_streams", %{"table" => name}, socket) do
    socket =
      socket
      |> assign_async([:db_streams], fn ->
        case DynamoDB.list_streams(name) do
          {:ok, %{"Streams" => streams}, _resp} ->
            streams =
              Enum.map(streams, fn %{"StreamArn" => stream_arn} = stream ->
                desc =
                  case DynamoDB.describe_stream(stream_arn) do
                    {:ok, %{"StreamDescription" => desc}, _resp} ->
                      desc
                      |> Map.take(
                        ~w[CreationRequestDateTime KeySchema Shards StreamStatus StreamViewType]
                      )

                    {:error, reason} ->
                      reason
                  end

                stream
                |> Map.merge(desc)
              end)

            {:ok, %{db_streams: streams}}

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

  defp apply_action(socket, :scan, %{"table" => table} = _params) do
    socket
    |> assign(:page_title, "AWS DynamoD Table: #{table}")
    |> assign(:table, table)
    |> assign(:table_data, %Phoenix.LiveView.AsyncResult{ok?: false, loading: true})
    |> assign_async([:table_data], fn ->
      case GSMLG.AWS.DynamoDB.scan_table(table, %{"limit" => 10}) do
        {:ok, table_data, _resp} ->
          # %{
          #   "ConsumedCapacity" => consumed_capacity(),
          #   "Count" => integer(),
          #   "Items" => list(map()()),
          #   "LastEvaluatedKey" => map(),
          #   "ScannedCount" => integer()
          # }
          {:ok, %{table_data: table_data}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end
end
