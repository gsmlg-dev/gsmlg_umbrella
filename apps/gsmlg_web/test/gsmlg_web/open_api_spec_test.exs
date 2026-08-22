defmodule GSMLG.Web.OpenApiSpecTest do
  use ExUnit.Case, async: true

  alias OpenApiSpex.OpenApi

  setup do
    spec = GSMLG.Web.ApiSpec.spec()
    document = OpenApi.to_map(spec)

    %{
      spec: spec,
      document: document,
      schemas: document["components"]["schemas"],
      components: document["components"]
    }
  end

  test "builds a serializable OpenAPI document with resolvable schema references", %{
    spec: spec,
    document: document,
    schemas: schemas
  } do
    assert %OpenApi{} = spec

    assert document ==
             document
             |> OpenApi.from_map()
             |> OpenApi.to_map()

    assert {:ok, _json} = Jason.encode(document)

    referenced_schema_names =
      document
      |> collect_refs()
      |> Enum.filter(&String.starts_with?(&1, "#/components/schemas/"))
      |> Enum.map(&String.replace_prefix(&1, "#/components/schemas/", ""))
      |> MapSet.new()

    assert MapSet.subset?(referenced_schema_names, MapSet.new(Map.keys(schemas)))
  end

  test "documents every field emitted for a note as required", %{schemas: schemas} do
    assert required_fields(schemas["Note"]) ==
             MapSet.new(~w(id title content labels attachments created_at updated_at))
  end

  test "documents required create note fields", %{schemas: schemas} do
    assert required_fields(schemas["NoteCreateInput"]) == MapSet.new(~w(title content))
  end

  test "documents attachments as required for note updates", %{schemas: schemas} do
    assert required_fields(schemas["NoteUpdateInput"]) == MapSet.new(~w(attachments))
  end

  test "rejects undocumented attachment input fields", %{schemas: schemas} do
    assert required_fields(schemas["AttachmentInput"]) == MapSet.new(~w(id path mime))
    assert schemas["AttachmentInput"]["additionalProperties"] == false
  end

  test "documents the web push subscription wrapper", %{schemas: schemas} do
    assert required_fields(schemas["WebPushSubscriptionInput"]) == MapSet.new(~w(subscription))
  end

  test "documents the standard API error envelope", %{schemas: schemas} do
    assert required_fields(schemas["ApiError"]) == MapSet.new(~w(errors))
  end

  test "keeps the Guardian bearer security scheme", %{components: components} do
    assert components["securitySchemes"]["bearerAuth"] == %{
             "type" => "http",
             "scheme" => "bearer",
             "bearerFormat" => "JWT",
             "description" => "Guardian access token"
           }
  end

  test "documents the blog and GaoNote API operations", %{document: document} do
    paths = document["paths"]

    gao_notes = paths["/api/gao_notes"]
    note = paths["/api/gao_notes/{id}"]
    attachment = paths["/api/gao_notes/{note_id}/attachments/{path}"]

    assert %{"get" => %{"operationId" => "listBlogs"}} = paths["/api/blogs"]

    assert %{
             "get" => %{
               "operationId" => "listGaoNotes",
               "security" => [%{}, %{"bearerAuth" => []}]
             },
             "post" => %{"operationId" => "createGaoNote", "security" => [%{"bearerAuth" => []}]}
           } = gao_notes

    assert %{
             "get" => %{
               "operationId" => "listGaoNoteLabelSettings",
               "security" => [%{}, %{"bearerAuth" => []}]
             }
           } = paths["/api/gao_notes/label_settings"]

    assert %{
             "get" => %{"operationId" => "getGaoNote"},
             "put" => %{"operationId" => "replaceGaoNote"},
             "patch" => %{"operationId" => "patchGaoNote"}
           } = note

    assert %{
             "get" => %{"operationId" => "getGaoNoteAttachment"}
           } = attachment

    assert %{
             "schema" => %{"type" => "string"},
             "description" => "Filter by label key or key=value"
           } =
             parameter(gao_notes["get"], "label")

    assert_request_body(gao_notes["post"], "NoteCreateInput")
    assert_request_body(note["put"], "NoteUpdateInput")
    assert_request_body(note["patch"], "NoteUpdateInput")

    refute Map.has_key?(gao_notes["post"]["responses"], "404")
    assert_api_error_response(note["put"], "404")
    assert_api_error_response(note["patch"], "404")

    assert_auth_error_response(gao_notes["post"])
    assert_auth_error_response(note["put"])
    assert_auth_error_response(note["patch"])
    assert_auth_error_response(attachment["get"])

    attachment_path_parameter =
      parameter(attachment["get"], "path")

    assert %{
             "x-gsmlg-greedy-path" => true,
             "description" => description
           } = attachment_path_parameter

    assert description =~ "Greedily captures the remaining slash-delimited"
    assert description =~ "encode path segments appropriately"

    assert %{"required" => true} = parameter(note["get"], "id")
    assert %{"required" => true} = parameter(attachment["get"], "note_id")
    assert %{"required" => true} = attachment_path_parameter
    assert %{"required" => false} = parameter(attachment["get"], "Range")

    assert_binary_response(attachment["get"], "200")
    assert_binary_response(attachment["get"], "206")
    refute Map.has_key?(attachment["get"]["responses"], "400")
    assert_api_error_response(attachment["get"], "404")
    assert %{"description" => _description} = attachment["get"]["responses"]["416"]
    refute Map.has_key?(attachment["get"]["responses"]["416"], "content")
  end

  test "documents toolbox, web push, and proxy rules operations with runtime fidelity", %{
    document: document
  } do
    paths = document["paths"]

    assert %{"get" => %{"operationId" => "ipGeo"} = ip_geo} = paths["/api/toolbox/ip_geo"]
    assert %{"get" => %{"operationId" => "whois"} = whois} = paths["/api/toolbox/whois"]
    assert %{"get" => %{"operationId" => "rdap"} = rdap} = paths["/api/toolbox/whois/rdap"]

    assert %{"get" => %{"operationId" => "macManufacturer"} = mac} =
             paths["/api/toolbox/mac_manufacturer"]

    assert %{"get" => %{"operationId" => "ipToGeomap"} = ip_to_geomap} =
             paths["/api/toolbox/ip_to_geomap"]

    assert %{"get" => %{"operationId" => "getVapidPublicKey"} = vapid} =
             paths["/api/vapid-public-key"]

    assert %{"post" => %{"operationId" => "subscribeWebPush"} = subscribe} =
             paths["/api/subscribe"]

    assert %{"post" => %{"operationId" => "sendWebPushNotification"} = send_notification} =
             paths["/api/send-notification"]

    assert %{"get" => %{"operationId" => "getProxyRules"} = proxy_rules} =
             paths["/api/proxy-rules/{list}/{format}"]

    for operation <- [ip_geo, whois, rdap, mac, ip_to_geomap, vapid, subscribe] do
      assert operation["security"] == [%{}, %{"bearerAuth" => []}]
    end

    assert send_notification["security"] == [%{"bearerAuth" => []}]
    assert proxy_rules["security"] == []

    assert %{"required" => true, "schema" => %{"type" => "string"}} =
             parameter(ip_geo, "ip")

    assert %{"required" => true, "schema" => %{"type" => "string"}} =
             parameter(whois, "look_for")

    assert %{
             "schema" => %{
               "type" => "string",
               "enum" => ["domain", "ip", "asn"],
               "default" => "domain"
             }
           } = parameter(rdap, "type")

    assert %{"required" => true, "schema" => %{"type" => "string"}} = parameter(mac, "mac")

    assert %{"required" => true, "schema" => %{"type" => "string"}} =
             parameter(ip_to_geomap, "ip")

    assert_json_response(ip_geo, "200", "GeoEnvelope")
    assert_json_response(ip_geo, "422", "SimpleError")
    assert_json_response(ip_to_geomap, "200", "GeoEnvelope")
    refute Map.has_key?(ip_to_geomap["responses"], "422")
    assert_json_response(vapid, "200", "VapidKeyEnvelope")

    assert_request_body(subscribe, "WebPushSubscriptionInput")
    assert_json_response(subscribe, "200", "StatusEnvelope")
    assert_json_response(subscribe, "422", "SubscriptionError")
    assert_request_body(send_notification, "NotificationInput")
    assert_auth_error_response(send_notification)
    assert subscribe["description"] =~ "does not enforce"
    assert send_notification["description"] =~ "dispatch attempted"

    assert %{"schema" => %{"type" => "string", "enum" => ["proxy-list", "direct-list"]}} =
             parameter(proxy_rules, "list")

    assert %{"schema" => %{"type" => "string", "enum" => ["raw", "squid", "clash"]}} =
             parameter(proxy_rules, "format")

    assert %{"required" => false, "in" => "header"} = parameter(proxy_rules, "If-None-Match")

    for status <- ["200", "404", "503"] do
      assert %{
               "content" => %{
                 "text/plain" => %{"schema" => %{"type" => "string"}}
               }
             } = proxy_rules["responses"][status]
    end

    assert %{"description" => _description} = proxy_rules["responses"]["304"]
    refute Map.has_key?(proxy_rules["responses"]["304"], "content")

    for status <- ["200", "304"], header <- proxy_response_header_names() do
      assert %{"description" => _description, "schema" => %{"type" => "string"}} =
               proxy_rules["responses"][status]["headers"][header]
    end
  end

  test "matches the public API router operation surface", %{document: document} do
    router_operation_pairs =
      GSMLG.Web.Router.__routes__()
      |> Enum.filter(fn route ->
        route.path == "/api" or String.starts_with?(route.path, "/api/")
      end)
      |> Enum.reject(&(&1.path == "/api/*request_path"))
      |> Enum.filter(&(&1.verb in [:get, :post, :put, :patch, :delete]))
      |> Enum.map(&{&1.verb, normalize_api_path(&1.path)})
      |> MapSet.new()

    assert router_operation_pairs == operation_pairs(document)
    assert MapSet.size(router_operation_pairs) == 18
    assert MapSet.member?(router_operation_pairs, {:get, "/api/openapi.json"})

    refute Enum.any?(router_operation_pairs, fn {_verb, path} ->
             String.contains?(path, "/mcp")
           end)

    refute MapSet.member?(router_operation_pairs, {:get, "/api/blogs/{id}"})
  end

  defp required_fields(schema), do: MapSet.new(schema["required"])

  defp operation_pairs(document) do
    document["paths"]
    |> Enum.flat_map(fn {path, operations} ->
      for {verb, _operation} <- operations,
          verb in ~w(get post put patch delete),
          do: {String.to_existing_atom(verb), path}
    end)
    |> MapSet.new()
  end

  defp normalize_api_path(path) do
    Regex.replace(~r/[:*]([a-zA-Z_][a-zA-Z0-9_]*)/, path, "{\\1}")
  end

  defp parameter(operation, name) do
    Enum.find(operation["parameters"], &(&1["name"] == name))
  end

  defp assert_request_body(operation, schema_name) do
    assert %{
             "requestBody" => %{
               "content" => %{
                 "application/json" => %{
                   "schema" => %{"$ref" => "#/components/schemas/" <> ^schema_name}
                 }
               }
             }
           } = operation
  end

  defp assert_auth_error_response(operation) do
    assert %{
             "content" => %{
               "application/json" => %{
                 "schema" => %{"$ref" => "#/components/schemas/AuthError"}
               }
             }
           } = operation["responses"]["401"]
  end

  defp assert_json_response(operation, status, schema_name) do
    assert %{
             "content" => %{
               "application/json" => %{
                 "schema" => %{"$ref" => "#/components/schemas/" <> ^schema_name}
               }
             }
           } = operation["responses"][status]
  end

  defp assert_api_error_response(operation, status) do
    assert %{
             "content" => %{
               "application/json" => %{
                 "schema" => %{"$ref" => "#/components/schemas/ApiError"}
               }
             }
           } = operation["responses"][status]
  end

  defp assert_binary_response(operation, status) do
    assert %{
             "content" => %{
               "*/*" => %{"schema" => %{"type" => "string", "format" => "binary"}}
             }
           } = operation["responses"][status]
  end

  defp proxy_response_header_names do
    ["ETag", "Last-Modified", "Cache-Control", "X-Proxy-Rules-Generation"]
  end

  defp collect_refs(value) when is_map(value) do
    Enum.flat_map(value, fn
      {"$ref", ref} when is_binary(ref) -> [ref]
      {_key, nested} -> collect_refs(nested)
    end)
  end

  defp collect_refs(value) when is_list(value), do: Enum.flat_map(value, &collect_refs/1)
  defp collect_refs(_value), do: []
end
