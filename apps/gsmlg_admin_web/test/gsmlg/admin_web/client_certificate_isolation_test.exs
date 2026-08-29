defmodule GSMLG.AdminWeb.ClientCertificateIsolationTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import GSMLG.AccountsFixtures
  import GSMLG.AdminWeb.ClientCertificateFixtures

  alias GSMLG.Accounts

  setup %{conn: conn} do
    endpoint = GSMLG.AdminWeb.Endpoint
    original = Application.get_env(:gsmlg_admin_web, endpoint, [])

    Application.put_env(
      :gsmlg_admin_web,
      endpoint,
      Keyword.put(original, :client_certificate_auth, true)
    )

    on_exit(fn -> Application.put_env(:gsmlg_admin_web, endpoint, original) end)

    user = user_fixture()
    certificate = client_certificate()

    assert {:ok, _binding} =
             Accounts.bind_user_client_certificate(user, %{
               certificate_der: certificate.certificate_der,
               subject: certificate.subject,
               email: certificate.email
             })

    %{conn: put_client_certificate_headers(conn, certificate)}
  end

  test "certificate headers do not authenticate API sign-out", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> delete(~p"/api/sign_out")

    assert json_response(conn, 401)["message"] =~ "unauthenticated"
  end

  test "certificate headers do not authenticate browser JSON routes", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> get(~p"/proxy-rules/sources/gfwlist")

    assert redirected_to(conn) == "/sign_in"
  end

  test "certificate headers do not authenticate MCP", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> post(~p"/mcp/gao_note", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{}
      })

    assert json_response(conn, 401)["message"] =~ "no_resource"
  end
end
