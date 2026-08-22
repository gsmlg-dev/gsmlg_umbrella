defmodule GSMLG.Web.OpenApi.ProxyRulesOperations do
  @moduledoc false

  alias GSMLG.Web.OpenApi.Operation

  def paths do
    %{
      "/api/proxy-rules/{list}/{format}" => %{"get" => get_proxy_rules()}
    }
  end

  defp get_proxy_rules do
    Operation.operation(
      "getProxyRules",
      "Proxy Rules",
      "Get a compiled proxy-rules artifact",
      %{
        "200" =>
          plain_response("Compiled proxy-rules artifact")
          |> with_response_headers(),
        "304" =>
          Operation.response("Artifact has not changed")
          |> with_response_headers(),
        "404" => plain_response("Artifact not found"),
        "503" => plain_response("Proxy-rules service unavailable")
      },
      parameters: [
        Operation.parameter(
          "list",
          "path",
          %{"type" => "string", "enum" => ["proxy-list", "direct-list"]},
          "Artifact list"
        ),
        Operation.parameter(
          "format",
          "path",
          %{"type" => "string", "enum" => ["raw", "squid", "clash"]},
          "Artifact format"
        ),
        Operation.parameter(
          "If-None-Match",
          "header",
          %{"type" => "string"},
          "Return 304 when the supplied ETag matches"
        )
      ],
      security: []
    )
  end

  defp plain_response(description) do
    Operation.response(description, "text/plain", %{"type" => "string"})
  end

  defp with_response_headers(response) do
    Map.put(response, "headers", %{
      "ETag" => header("Entity tag for this artifact representation"),
      "Last-Modified" => header("When this artifact was last modified"),
      "Cache-Control" => header("Caching directives for this artifact"),
      "X-Proxy-Rules-Generation" => header("Proxy-rules generation number")
    })
  end

  defp header(description) do
    %{"description" => description, "schema" => %{"type" => "string"}}
  end
end
