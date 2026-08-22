defmodule GSMLG.Web.OpenApi.Operations do
  @moduledoc false

  alias GSMLG.Web.OpenApi.{
    BlogOperations,
    GaoNoteOperations,
    Operation,
    ProxyRulesOperations,
    ToolboxOperations,
    WebPushOperations,
    ZeroOmegaOperations
  }

  def paths do
    [
      self_path(),
      BlogOperations.paths(),
      GaoNoteOperations.paths(),
      ToolboxOperations.paths(),
      WebPushOperations.paths(),
      ProxyRulesOperations.paths(),
      ZeroOmegaOperations.paths()
    ]
    |> Enum.reduce(&deep_merge_paths/2)
  end

  def deep_merge_paths(left, right) do
    Map.merge(left, right, fn path, left_operations, right_operations ->
      Map.merge(left_operations, right_operations, fn verb, _left_operation, _right_operation ->
        raise ArgumentError, "duplicate OpenAPI operation #{verb} for #{path}"
      end)
    end)
  end

  defp self_path do
    %{
      "/api/openapi.json" => %{
        "get" =>
          Operation.operation(
            "getOpenApiDocument",
            "Discovery",
            "Return the OpenAPI document",
            %{
              "200" =>
                Operation.response(
                  "OpenAPI 3.0.3 document",
                  "application/json",
                  %{"type" => "object", "additionalProperties" => true}
                )
            },
            security: []
          )
      }
    }
  end
end
