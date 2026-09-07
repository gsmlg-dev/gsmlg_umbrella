defmodule GSMLG.AdminWeb.BrowserAPI.OpenApiTest do
  use GSMLG.AdminWeb.ConnCase, async: true

  alias GSMLG.AdminWeb.BrowserAPI.Request
  alias GSMLG.AdminWeb.Router
  alias OpenApiSpex.OpenApi

  test "spec is serializable, closed, authenticated, and exactly matches the 25 routes" do
    document = GSMLG.AdminWeb.BrowserApiSpec.spec() |> OpenApi.to_map()

    assert document == document |> OpenApi.from_map() |> OpenApi.to_map()
    assert is_binary(JSON.encode!(document))

    documented =
      for {path, path_item} <- document["paths"],
          {method, operation} <- path_item,
          method in ~w(get post put patch delete),
          into: MapSet.new() do
        assert operation["security"] == [%{"browserBearerAuth" => []}]
        {String.to_atom(method), path}
      end

    routed =
      Router.__routes__()
      |> Enum.filter(fn route ->
        String.starts_with?(route.path, "/api/browser/") and
          route.path != "/api/browser/openapi.json" and route.verb != :*
      end)
      |> Enum.map(fn route ->
        path = Regex.replace(~r{:([^/]+)}, route.path, "{\\1}")
        {route.verb, path}
      end)
      |> MapSet.new()

    assert MapSet.size(routed) == 25
    assert documented == routed

    schemas = document["components"]["schemas"]

    assert schemas["BrowserError"]["required"] |> MapSet.new() ==
             MapSet.new(~w(class code message retryable human_action details))

    assert schemas["BrowserError"]["additionalProperties"] == false

    for {_name, schema} <- schemas do
      if schema["type"] == "object", do: assert(schema["additionalProperties"] == false)
    end

    assert schemas["DeepResearchInput"]["properties"]["auto_approve_plan"] == %{
             "type" => "boolean"
           }

    required_sections = schemas["DeepResearchInput"]["properties"]["required_sections"]
    assert required_sections["maxItems"] == 32
    assert required_sections["items"]["maxLength"] == 128

    job_variants = schemas["JobCreateInput"]["oneOf"]
    assert length(job_variants) == 2

    assert Enum.map(job_variants, &get_in(&1, ["properties", "workflow", "enum"])) == [
             ["gemini.deep_research"],
             ["gemini.youtube_analysis"]
           ]

    assert Enum.map(job_variants, &get_in(&1, ["properties", "input", "$ref"])) == [
             "#/components/schemas/DeepResearchInput",
             "#/components/schemas/YouTubeAnalysisInput"
           ]

    for variant <- job_variants,
        formats = variant["properties"]["output_formats"]["enum"],
        format_list <- formats do
      assert Enum.uniq(format_list) == format_list
      assert length(format_list) in 3..5
      assert Enum.all?(~w(report.markdown report.json sources.json), &(&1 in format_list))
    end

    assert job_variants
           |> hd()
           |> get_in(["properties", "output_formats", "enum"])
           |> length() == 174

    youtube_pattern =
      schemas["YouTubeAnalysisInput"]["properties"]["youtube_url"]["pattern"]
      |> Regex.compile!()

    assert "https://www.youtube.com/watch?list=bounded&v=abcdef" =~ youtube_pattern
    assert "https://youtu.be/abcdef" =~ youtube_pattern
    refute "https://example.com/watch?v=abcdef" =~ youtube_pattern
    refute "https://www.youtube.com/watch?notv=abcdef" =~ youtube_pattern

    action_variants = schemas["ActionInput"]["oneOf"]
    assert length(action_variants) == 12

    assert action_variants
           |> Enum.map(&get_in(&1, ["properties", "type", "enum"]))
           |> List.flatten()
           |> MapSet.new() ==
             MapSet.new(
               ~w(navigate click focus fill insert_text press_key select_option scroll wait_for extract screenshot download)
             )

    locator_actions =
      MapSet.new(~w(click focus fill insert_text select_option wait_for extract download))

    for variant <- action_variants do
      [type] = get_in(variant, ["properties", "type", "enum"])
      assert "locator" in variant["required"] == MapSet.member?(locator_actions, type)

      if MapSet.member?(locator_actions, type) do
        assert get_in(variant, ["properties", "locator", "$ref"]) ==
                 "#/components/schemas/Locator"
      else
        assert get_in(variant, ["properties", "locator", "enum"]) == [nil]
      end

      [postcondition, no_postcondition] =
        get_in(variant, ["properties", "postcondition", "oneOf"])

      assert postcondition == %{"$ref" => "#/components/schemas/Postcondition"}
      assert no_postcondition["type"] == "object"
      assert no_postcondition["nullable"] == true
      assert no_postcondition["enum"] == [nil]
    end

    navigate_pattern =
      action_variants
      |> Enum.find(&(get_in(&1, ["properties", "type", "enum"]) == ["navigate"]))
      |> get_in(["properties", "input", "properties", "url", "pattern"])
      |> Regex.compile!()

    assert "https://example.com/path" =~ navigate_pattern
    refute "https://" =~ navigate_pattern
    refute "https://user@example.com/path" =~ navigate_pattern

    assert "result" in schemas["Job"]["required"]

    [result, no_result] = schemas["Job"]["properties"]["result"]["oneOf"]
    assert result == %{"$ref" => "#/components/schemas/ResultManifest"}
    assert no_result["nullable"] == true
    assert no_result["enum"] == [nil]

    assert schemas["ResultManifest"]["required"] |> MapSet.new() ==
             MapSet.new(~w(last_sequence artifact_count pending_artifact_count remote_completed))

    assert schemas["ResultManifest"]["additionalProperties"] == false
    assert schemas["ResultManifest"]["properties"]["last_sequence"]["maximum"] == 1_000_000_000

    profile_configuration_variants = schemas["ProfileConfigurationInput"]["oneOf"]
    assert length(profile_configuration_variants) == 2

    for variant <- profile_configuration_variants do
      assert MapSet.new(variant["required"]) ==
               MapSet.new(~w(enabled is_default allowed_origins))

      assert variant["additionalProperties"] == false
      assert variant["properties"]["allowed_origins"]["minItems"] == 1
      assert variant["properties"]["allowed_origins"]["items"]["pattern"] =~ "^https://"
    end

    default_variant =
      Enum.find(
        profile_configuration_variants,
        &(get_in(&1, ["properties", "is_default", "enum"]) == [true])
      )

    assert get_in(default_variant, ["properties", "enabled", "enum"]) == [true]
    assert schemas["Profile"]["properties"]["allowed_origins"]["maxItems"] == 16
    assert schemas["Profile"]["properties"]["allowed_origins"]["minItems"] == 0

    assert schemas["Page"]["properties"]["next_after"]["anyOf"] == [
             %{"type" => "string", "nullable" => true},
             %{"type" => "integer", "nullable" => true}
           ]

    assert Enum.all?(action_variants, &("expected_revision" in &1["required"]))
    assert "origin" in schemas["Observation"]["required"]
    assert "loading_state" in schemas["Observation"]["required"]
    refute Enum.any?(action_variants, &Map.has_key?(&1["properties"], "session_id"))
    refute Enum.any?(job_variants, &Map.has_key?(&1["properties"], "deadline_at"))

    assert schemas["SessionCreateInput"]["properties"]["permissions"] == %{
             "$ref" => "#/components/schemas/SessionPermissions"
           }

    assert schemas["SessionPermissions"]["additionalProperties"] == false

    assert schemas["ActionOutput"]["properties"]["artifact"] == %{
             "$ref" => "#/components/schemas/ActionArtifactReference"
           }

    assert schemas["Artifact"]["oneOf"] == [
             %{"required" => ["job_id"]},
             %{"required" => ["session_id"]}
           ]

    locator_attributes =
      schemas["Locator"]["oneOf"]
      |> Enum.find(&Map.has_key?(&1["properties"], "attribute"))
      |> get_in(["properties", "attribute", "properties", "name", "enum"])

    assert locator_attributes == ~w(aria-controls type)

    forbidden =
      ~w(raw_cdp javascript cookie local_storage indexed_db password client_key manager_token profile_path)

    property_names = collect_property_names(schemas)
    assert MapSet.disjoint?(property_names, MapSet.new(forbidden))

    artifact_responses =
      document["paths"]["/api/browser/artifacts/{id}/content"]["get"]["responses"]

    expected_media =
      MapSet.new(
        ~w(application/octet-stream application/pdf application/json text/html text/markdown text/plain image/png image/jpeg)
      )

    for status <- ~w(200 206) do
      response = artifact_responses[status]
      assert response["content"] |> Map.keys() |> MapSet.new() == expected_media
      assert response["headers"]["Accept-Ranges"]["schema"]["enum"] == ["bytes"]
      assert response["headers"]["Content-Disposition"]["schema"]["type"] == "string"
    end

    assert artifact_responses["206"]["headers"]["Content-Range"]["required"] == true
    assert artifact_responses["416"]["headers"]["Content-Range"]["required"] == true
  end

  test "request schemas cast the same security-sensitive null and origin boundary values as runtime" do
    spec = GSMLG.AdminWeb.BrowserApiSpec.spec()
    session_schema = spec.components.schemas["SessionCreateInput"]
    result_schema = spec.components.schemas["Job"].properties[:result]
    id = Ecto.UUID.generate()

    valid = %{
      "node" => id,
      "profile" => id,
      "mode" => "automation",
      "authorized_origins" => ["https://example.com:8443"],
      "ttl" => 1
    }

    assert {:ok, _runtime} = Request.session(valid)
    assert {:ok, _cast} = OpenApiSpex.cast_value(valid, session_schema, spec)
    assert {:ok, nil} = OpenApiSpex.cast_value(nil, result_schema, spec)

    invalid_origins = [
      "https://localhost",
      "https://service.localhost",
      "https://service.local",
      "https://service.internal",
      "https://127.0.0.1",
      "https://10.2.3.4",
      "https://169.254.1.1",
      "https://172.16.1.1",
      "https://192.168.1.1",
      "https://[::1]",
      "https://[fc00::1]",
      "https://[fe80::1]",
      "https://[ff02::1]",
      "https://example.com:443",
      "https://example.com:99999"
    ]

    for origin <- invalid_origins do
      value = put_in(valid, ["authorized_origins"], [origin])
      assert {:error, "invalid_request"} = Request.session(value), origin
      assert {:error, _errors} = OpenApiSpex.cast_value(value, session_schema, spec), origin
    end
  end

  test "protected spec and Admin-origin catalog expose only the Browser document", %{conn: conn} do
    conn = authenticated_conn(conn)

    spec_conn = get(conn, "/api/browser/openapi.json")
    assert %{"openapi" => "3.0.3"} = json_response(spec_conn, 200)
    assert ["no-store"] = get_resp_header(spec_conn, "cache-control")
    assert ["nosniff"] = get_resp_header(spec_conn, "x-content-type-options")

    catalog_conn = conn |> recycle() |> get("/.well-known/api-catalog")

    assert [content_type] = get_resp_header(catalog_conn, "content-type")
    assert content_type =~ "application/linkset+json"

    assert [~s(</.well-known/api-catalog>; rel="api-catalog")] =
             get_resp_header(catalog_conn, "link")

    assert %{
             "linkset" => [
               %{
                 "anchor" => "/api/browser",
                 "service-desc" => [
                   %{"href" => "/api/browser/openapi.json", "type" => "application/json"}
                 ]
               }
             ]
           } = json_response(catalog_conn, 200)
  end

  defp collect_property_names(value) when is_map(value) do
    own = value |> Map.get("properties", %{}) |> Map.keys() |> MapSet.new()

    Enum.reduce(value, own, fn {_key, nested}, names ->
      MapSet.union(names, collect_property_names(nested))
    end)
  end

  defp collect_property_names(value) when is_list(value) do
    Enum.reduce(value, MapSet.new(), &MapSet.union(&2, collect_property_names(&1)))
  end

  defp collect_property_names(_value), do: MapSet.new()

  defp authenticated_conn(conn) do
    user = GSMLG.AccountsFixtures.user_fixture()

    {:ok, token, _claims} =
      GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

    put_req_header(conn, "authorization", "Bearer #{token}")
  end
end
