defmodule GSMLG.Web.OpenApi.ToolboxOperations do
  @moduledoc false

  alias GSMLG.Web.OpenApi.Operation

  def paths do
    %{
      "/api/toolbox/ip_geo" => %{"get" => ip_geo()},
      "/api/toolbox/whois" => %{"get" => whois()},
      "/api/toolbox/whois/rdap" => %{"get" => rdap()},
      "/api/toolbox/mac_manufacturer" => %{"get" => mac_manufacturer()},
      "/api/toolbox/ip_to_geomap" => %{"get" => ip_to_geomap()}
    }
  end

  defp ip_geo do
    Operation.operation(
      "ipGeo",
      "Toolbox",
      "Look up IP geolocation",
      %{
        "200" => Operation.json_response("IP geolocation", "GeoEnvelope"),
        "422" => Operation.json_response("Invalid IP address", "SimpleError")
      },
      parameters: [Operation.parameter("ip", "query", string(), "IP address", true)],
      security: Operation.anonymous_or_bearer()
    )
  end

  defp whois do
    Operation.operation(
      "whois",
      "Toolbox",
      "Look up WHOIS data",
      %{
        "200" => Operation.json_response("WHOIS data", "WhoisEnvelope"),
        "422" => Operation.json_response("Invalid lookup", "SimpleError")
      },
      parameters: [
        Operation.parameter("look_for", "query", string(), "Domain or IP to look up", true)
      ],
      security: Operation.anonymous_or_bearer()
    )
  end

  defp rdap do
    Operation.operation(
      "rdap",
      "Toolbox",
      "Look up RDAP data",
      %{
        "200" => Operation.json_response("RDAP data", "RdapEnvelope"),
        "422" => Operation.json_response("Invalid lookup", "SimpleError")
      },
      parameters: [
        Operation.parameter("look_for", "query", string(), "Value to look up", true),
        Operation.parameter(
          "type",
          "query",
          %{"type" => "string", "enum" => ["domain", "ip", "asn"], "default" => "domain"},
          "RDAP lookup type"
        )
      ],
      security: Operation.anonymous_or_bearer()
    )
  end

  defp mac_manufacturer do
    Operation.operation(
      "macManufacturer",
      "Toolbox",
      "Look up MAC address manufacturer",
      %{
        "200" => Operation.json_response("MAC address manufacturer", "MacVendorEnvelope"),
        "404" => Operation.json_response("Manufacturer not found", "SimpleError")
      },
      parameters: [Operation.parameter("mac", "query", string(), "MAC address", true)],
      security: Operation.anonymous_or_bearer()
    )
  end

  defp ip_to_geomap do
    Operation.operation(
      "ipToGeomap",
      "Toolbox",
      "Look up IP geolocation for the geomap",
      %{"200" => Operation.json_response("IP geolocation", "GeoEnvelope")},
      parameters: [Operation.parameter("ip", "query", string(), "IP address", true)],
      security: Operation.anonymous_or_bearer()
    )
  end

  defp string, do: %{"type" => "string"}
end
