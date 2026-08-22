defmodule GSMLG.Web.OpenApi.ZeroOmegaOperations do
  @moduledoc false

  alias GSMLG.Web.OpenApi.Operation

  @head_description "HEAD mirrors GET through Plug.Head; no separate HEAD router operation is documented."

  def paths do
    %{
      "/rules/zeroomega/switchy" => %{"get" => get_switchy()},
      "/rules/zeroomega/pac" => %{"get" => get_pac()}
    }
  end

  defp get_switchy do
    Operation.operation(
      "getZeroOmegaSwitchy",
      "ZeroOmega",
      "Export a SwitchyOmega rule list",
      %{
        "200" => plain_response("SwitchyOmega rule list") |> with_response_headers(),
        "304" => Operation.response("Rule list has not changed") |> with_response_headers(),
        "400" => plain_response("Invalid ZeroOmega options"),
        "503" => plain_response("Proxy-rules service unavailable")
      },
      parameters: [
        Operation.parameter(
          "mode",
          "query",
          %{"type" => "string", "enum" => ["binary", "result"], "default" => "binary"},
          "SwitchyOmega export mode"
        ),
        Operation.parameter(
          "match_profile",
          "query",
          %{"type" => "string", "default" => "squid"},
          "Profile used for matched rules"
        ),
        Operation.parameter(
          "default_profile",
          "query",
          %{"type" => "string", "default" => "direct"},
          "Profile used when no rule matches"
        ),
        if_none_match_parameter()
      ],
      security: [],
      description: @head_description
    )
  end

  defp get_pac do
    Operation.operation(
      "getZeroOmegaPac",
      "ZeroOmega",
      "Export a proxy auto-configuration script",
      %{
        "200" =>
          Operation.response(
            "Proxy auto-configuration script",
            "application/x-ns-proxy-autoconfig",
            %{"type" => "string"}
          )
          |> with_response_headers(),
        "304" => Operation.response("PAC script has not changed") |> with_response_headers(),
        "400" => plain_response("Invalid ZeroOmega options"),
        "503" => plain_response("Proxy-rules service unavailable")
      },
      parameters: [
        Operation.parameter(
          "proxy",
          "query",
          %{"type" => "string", "example" => "10.100.0.1:3128"},
          "Proxy endpoint as bare host:port or [IPv6]:port, with port 1-65535; schemes, credentials, whitespace, and unsafe delimiters are not allowed.",
          true
        ),
        if_none_match_parameter()
      ],
      security: [],
      description: @head_description
    )
  end

  defp if_none_match_parameter do
    Operation.parameter(
      "If-None-Match",
      "header",
      %{"type" => "string"},
      "Return 304 when the supplied ETag matches"
    )
  end

  defp plain_response(description) do
    Operation.response(description, "text/plain", %{"type" => "string"})
  end

  defp with_response_headers(response) do
    Map.put(response, "headers", %{
      "ETag" => header("Entity tag for this export representation"),
      "Last-Modified" => header("When this export was last modified"),
      "Cache-Control" => header("Caching directives for this export"),
      "X-Proxy-Rules-Generation" => header("Proxy-rules generation number"),
      "Content-Length" => header("Length of the export representation in bytes")
    })
  end

  defp header(description) do
    %{"description" => description, "schema" => %{"type" => "string"}}
  end
end
