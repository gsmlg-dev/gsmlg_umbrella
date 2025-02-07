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

  defp get_client() do
    GSMLG.AWS.Client.get_client()
  end
end
