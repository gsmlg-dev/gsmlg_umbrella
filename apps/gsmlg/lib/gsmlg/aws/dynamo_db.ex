defmodule GSMLG.AWS.DynamoDB do
  require Logger

  alias AWS.DynamoDB

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

  defdelegate get_client(), to: GSMLG.AWS.Client
end
