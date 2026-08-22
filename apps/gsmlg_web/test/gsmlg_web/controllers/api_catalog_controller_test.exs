defmodule GSMLG.Web.ApiCatalogControllerTest do
  use GSMLG.Web.ConnCase

  @profile "https://www.rfc-editor.org/info/rfc9727"
  @content_type ~s(application/linkset+json; profile="#{@profile}")

  test "GET /.well-known/api-catalog returns the API catalog linkset", %{conn: conn} do
    conn = get(conn, "/.well-known/api-catalog")

    assert [@content_type] = get_resp_header(conn, "content-type")
    assert [~s(</.well-known/api-catalog>; rel="api-catalog")] = get_resp_header(conn, "link")

    assert %{
             "linkset" => [
               %{
                 "anchor" => "/api",
                 "service-desc" => [
                   %{"href" => "/api/openapi.json", "type" => "application/json"}
                 ]
               },
               %{
                 "anchor" => "/rules/zeroomega",
                 "service-desc" => [
                   %{"href" => "/api/openapi.json", "type" => "application/json"}
                 ]
               }
             ]
           } == json_response(conn, 200)

    refute conn.resp_body =~ "/mcp"
    refute conn.resp_body =~ "/files"
    refute conn.resp_body =~ "/admin"
    refute conn.resp_body =~ "/api/sign_in"
    refute conn.resp_body =~ "/api/blogs/{id}"
  end

  test "HEAD /.well-known/api-catalog returns the API catalog headers without a body", %{
    conn: conn
  } do
    conn = head(conn, "/.well-known/api-catalog")

    assert conn.status == 200
    assert [@content_type] = get_resp_header(conn, "content-type")
    assert [~s(</.well-known/api-catalog>; rel="api-catalog")] = get_resp_header(conn, "link")
    assert conn.resp_body == ""
  end
end
