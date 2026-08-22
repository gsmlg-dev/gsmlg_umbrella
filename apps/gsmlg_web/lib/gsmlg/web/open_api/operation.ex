defmodule GSMLG.Web.OpenApi.Operation do
  @moduledoc false

  @anonymous_or_bearer [%{}, %{"bearerAuth" => []}]
  @bearer [%{"bearerAuth" => []}]

  def anonymous_or_bearer, do: @anonymous_or_bearer
  def bearer, do: @bearer

  def ref(name), do: %{"$ref" => "#/components/schemas/#{name}"}

  def parameter(name, location, schema, description, required \\ false) do
    %{
      "name" => name,
      "in" => location,
      "required" => required or location == "path",
      "description" => description,
      "schema" => schema
    }
  end

  def json_response(description, schema_name) do
    response(description, "application/json", ref(schema_name))
  end

  def response(description) do
    %{"description" => description}
  end

  def response(description, media_type, schema) do
    %{
      "description" => description,
      "content" => %{media_type => %{"schema" => schema}}
    }
  end

  def request_body(schema_name, description) do
    %{
      "description" => description,
      "required" => true,
      "content" => %{"application/json" => %{"schema" => ref(schema_name)}}
    }
  end

  def operation(operation_id, tag, summary, responses, opts \\ []) do
    %{
      "operationId" => operation_id,
      "tags" => [tag],
      "summary" => summary,
      "parameters" => Keyword.get(opts, :parameters, []),
      "responses" => responses,
      "security" => Keyword.fetch!(opts, :security)
    }
    |> maybe_put("description", Keyword.get(opts, :description))
    |> maybe_put("requestBody", Keyword.get(opts, :request_body))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
