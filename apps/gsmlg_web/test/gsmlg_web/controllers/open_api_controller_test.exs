defmodule GSMLG.Web.OpenApiControllerTest do
  use GSMLG.Web.ConnCase

  test "GET /api/openapi.json renders the OpenAPI document", %{conn: conn} do
    conn = get(conn, ~p"/api/openapi.json")

    assert ["application/json; charset=utf-8"] = get_resp_header(conn, "content-type")

    assert %{
             "openapi" => "3.0.3",
             "info" => %{"title" => "GSMLG Web API"},
             "paths" => %{
               "/api/openapi.json" => %{
                 "get" => %{"operationId" => "getOpenApiDocument"}
               }
             }
           } = json_response(conn, 200)
  end
end
