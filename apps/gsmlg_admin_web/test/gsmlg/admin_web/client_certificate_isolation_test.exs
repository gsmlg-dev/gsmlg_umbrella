defmodule GSMLG.AdminWeb.ClientCertificateIsolationTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  require Phoenix.ChannelTest

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

    %{conn: put_client_certificate_headers(conn, certificate), certificate: certificate}
  end

  test "certificate headers do not authenticate bearer HTTP endpoints", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> post(~p"/api/scout/fetch", %{})

    assert json_response(conn, 401)["message"] =~ "no_resource"
  end

  test "certificate headers do not authenticate UserSocket", %{certificate: certificate} do
    assert {:ok, socket} =
             Phoenix.ChannelTest.connect(
               GSMLG.AdminWeb.UserSocket,
               %{"_csrf_token" => "csrf-token"},
               connect_info: %{
                 session: %{},
                 x_headers: client_certificate_headers(certificate)
               }
             )

    assert Guardian.Phoenix.Socket.current_resource(socket) == nil
    assert Guardian.Phoenix.Socket.current_token(socket) == nil
  end

  test "certificate headers do not affect CommanderSocket signature authentication", %{
    certificate: certificate
  } do
    original = Application.fetch_env(:gsmlg_commander, GSMLG.Commander)
    platform_key = :crypto.strong_rand_bytes(32)

    config =
      :gsmlg_commander
      |> Application.get_env(GSMLG.Commander, [])
      |> Keyword.put(:platform_key, platform_key)

    Application.put_env(:gsmlg_commander, GSMLG.Commander, config)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:gsmlg_commander, GSMLG.Commander, value)
        :error -> Application.delete_env(:gsmlg_commander, GSMLG.Commander)
      end
    end)

    name = "certificate-isolation"
    sign_at = Integer.to_string(System.system_time(:second))

    valid_signature =
      :crypto.mac(:hmac, :sha256, platform_key, "#{name}/#{sign_at}")
      |> Base.encode16()

    <<first, rest::binary>> = valid_signature
    different_first = if first == ?0, do: ?1, else: ?0
    invalid_signature = <<different_first, rest::binary>>
    headers = client_certificate_headers(certificate)

    assert {:error, :invalid_signature} =
             Phoenix.ChannelTest.connect(
               GSMLG.AdminWeb.CommanderSocket,
               %{"name" => name, "sign_at" => sign_at, "signature" => invalid_signature},
               connect_info: %{req_headers: headers, x_headers: headers}
             )
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
