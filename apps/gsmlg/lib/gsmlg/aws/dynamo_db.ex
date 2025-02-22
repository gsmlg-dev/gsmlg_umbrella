defmodule GSMLG.AWS.DynamoDB do
  require Logger

  alias AWS.DynamoDB
  alias AWS.DynamoDBStreams

  def list_tables(input \\ %{}) do
    input =
      input
      |> Map.merge(%{
        # "ExclusiveStartTableName" => "string",
        "Limit" => 10
      })

    get_client()
    |> DynamoDB.list_tables(input)
  end

  def describe_table(table_name) do
    get_client()
    |> DynamoDB.describe_table(%{"TableName" => table_name})
  end

  def scan_table(table_name, input \\ %{}) do
    input =
      input
      |> Map.merge(%{
        "TableName" => table_name
      })

    get_client()
    |> DynamoDB.scan(input)
  end

  def list_streams(table_name) do
    get_client()
    |> DynamoDBStreams.list_streams(%{"TableName" => table_name})
  end

  def describe_stream(stream_arn) do
    get_client()
    |> DynamoDBStreams.describe_stream(%{"StreamArn" => stream_arn})
  end

  defdelegate get_client(), to: GSMLG.AWS.Client
end
