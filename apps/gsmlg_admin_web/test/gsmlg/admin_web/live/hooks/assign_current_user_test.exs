defmodule GSMLG.AdminWeb.Live.Hooks.AssignCurrentUserTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import GSMLG.AccountsFixtures
  import GSMLG.AdminWeb.ClientCertificateFixtures
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias GSMLG.Accounts
  alias GSMLG.AdminWeb.Guardian
  alias GSMLG.AdminWeb.Plugs.ClientCertificateAuth

  setup do
    endpoint = GSMLG.AdminWeb.Endpoint
    original = Application.get_env(:gsmlg_admin_web, endpoint, [])

    Application.put_env(
      :gsmlg_admin_web,
      endpoint,
      Keyword.put(original, :client_certificate_auth, true)
    )

    on_exit(fn -> Application.put_env(:gsmlg_admin_web, endpoint, original) end)

    :ok
  end

  test "admin LiveViews disable Phoenix lifecycle logging" do
    original_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: original_level) end)

    unique = System.unique_integer([:positive])
    token = "guardian-token-sentinel-#{unique}"
    fingerprint = "certificate-fingerprint-sentinel-#{unique}"
    params_sentinel = "params-sentinel-#{unique}"

    socket = %Phoenix.LiveView.Socket{
      view: GSMLG.AdminWeb.GaoNoteLive.DashboardLive,
      transport_pid: self()
    }

    log =
      capture_log([level: :debug], fn ->
        Phoenix.LiveView.Logger.lv_mount_start(
          [:phoenix, :live_view, :mount, :start],
          %{system_time: System.system_time()},
          %{
            socket: socket,
            params: %{"sentinel" => params_sentinel},
            session: %{
              "guardian_default_token" => token,
              ClientCertificateAuth.fingerprint_key() => fingerprint
            },
            uri: "http://localhost/gao_notes"
          },
          %{}
        )
      end)

    refute log =~ "MOUNT"
    refute log =~ token
    refute log =~ fingerprint
    refute log =~ params_sentinel

    assert %{log: false} = GSMLG.AdminWeb.ProxyRulesLive.Index.__live__()
    assert %{log: false} = GSMLG.AdminWeb.GaoNoteLive.DashboardLive.__live__()
    assert %{log: false} = GSMLG.AdminWeb.S3Live.Index.__live__()
  end

  test "connected GaoNote LiveView does not log the certificate session", %{conn: conn} do
    original_level = Logger.level()
    original_ecto_levels = Logger.get_module_level(Ecto.Adapters.SQL)
    Logger.configure(level: :debug)
    Logger.put_module_level(Ecto.Adapters.SQL, :info)

    on_exit(fn ->
      Logger.configure(level: original_level)

      case original_ecto_levels do
        [{Ecto.Adapters.SQL, level}] -> Logger.put_module_level(Ecto.Adapters.SQL, level)
        [] -> Logger.delete_module_level(Ecto.Adapters.SQL)
      end
    end)

    user = user_fixture()
    certificate = client_certificate()
    assert {:ok, _binding} = bind_certificate(user, certificate)

    assert {:ok, guardian_token_sentinel, _claims} =
             Guardian.encode_and_sign(user, %{}, token_type: "access")

    fingerprint_sentinel = certificate.fingerprint
    headers = client_certificate_headers(certificate)

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> put_session(:guardian_default_token, guardian_token_sentinel)
      |> put_session(ClientCertificateAuth.auth_method_key(), "client_certificate")
      |> put_session(ClientCertificateAuth.fingerprint_key(), fingerprint_sentinel)
      |> put_client_certificate_headers(certificate)
      |> put_private(:live_view_connect_info, %{x_headers: headers})

    log =
      capture_log([level: :debug], fn ->
        assert {:ok, _view, _html} = live(conn, ~p"/gao_notes")
      end)

    refute log =~ guardian_token_sentinel
    refute log =~ fingerprint_sentinel
    refute log =~ "MOUNT GSMLG.AdminWeb.GaoNoteLive.DashboardLive"
    refute log =~ "Session:"
  end

  test "matching bound certificate permits a LiveView connection", %{conn: conn} do
    user = user_fixture()
    certificate = client_certificate()
    assert {:ok, _binding} = bind_certificate(user, certificate)

    headers = client_certificate_headers(certificate)

    conn =
      conn
      |> put_guardian_session(user, "client_certificate", certificate.fingerprint)
      |> put_client_certificate_headers(certificate)
      |> put_private(:live_view_connect_info, %{x_headers: headers})

    assert {:ok, _view, html} = live(conn, ~p"/gao_notes")
    assert html =~ ~s(data-admin-auth-method="client_certificate")
    assert html =~ ~s(data-admin-sign-out="true")
  end

  test "certificate session redirects when reconnect headers are absent", %{conn: conn} do
    {conn, _user, _certificate} = certificate_conn(conn)

    assert_certificate_expired(
      conn
      |> put_private(:live_view_connect_info, %{x_headers: []})
      |> live(~p"/gao_notes")
    )
  end

  test "certificate session redirects when reconnect headers are malformed", %{conn: conn} do
    {conn, _user, _certificate} = certificate_conn(conn)

    malformed_headers = [
      {"x-client-cert-subject", "CN=malformed.example.test"},
      {"x-client-cert-certificate-pem", "not-base64"},
      {"x-client-cert-email", "malformed@example.test"}
    ]

    assert_certificate_expired(
      conn
      |> put_private(:live_view_connect_info, %{x_headers: malformed_headers})
      |> live(~p"/gao_notes")
    )
  end

  test "certificate session redirects for unbound reconnect certificate", %{conn: conn} do
    {conn, _user, _certificate} = certificate_conn(conn)
    unbound_certificate = client_certificate()

    assert_certificate_expired(
      conn
      |> put_private(:live_view_connect_info, %{
        x_headers: client_certificate_headers(unbound_certificate)
      })
      |> live(~p"/gao_notes")
    )
  end

  test "certificate session redirects for a different owner's reconnect certificate", %{
    conn: conn
  } do
    {conn, _user, _certificate} = certificate_conn(conn)
    other_user = user_fixture(%{username: "other_owner", email: "other-owner@example.test"})
    other_certificate = client_certificate()
    assert {:ok, _binding} = bind_certificate(other_user, other_certificate)

    conn = get(conn, ~p"/gao_notes")
    assert conn.status == 200

    assert_certificate_expired(
      conn
      |> put_live_session(
        ClientCertificateAuth.fingerprint_key(),
        other_certificate.fingerprint
      )
      |> put_private(:live_view_connect_info, %{
        x_headers: client_certificate_headers(other_certificate)
      })
      |> live()
    )
  end

  test "password session connects without certificate headers", %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> put_guardian_session(user, "password")
      |> put_private(:live_view_connect_info, %{x_headers: []})

    assert {:ok, _view, _html} = live(conn, ~p"/gao_notes")
  end

  test "regular live_view macro validates certificate reconnects", %{conn: conn} do
    {conn, _user, _certificate} = certificate_conn(conn)

    assert_certificate_expired(
      conn
      |> put_private(:live_view_connect_info, %{x_headers: []})
      |> live(~p"/proxy-rules")
    )
  end

  test "aws_live_view macro validates certificate reconnects", %{conn: conn} do
    {conn, _user, _certificate} = certificate_conn(conn)

    assert_certificate_expired(
      conn
      |> put_private(:live_view_connect_info, %{x_headers: []})
      |> live(~p"/aws/s3/buckets")
    )
  end

  test "disabled certificate authentication preserves certificate-marked Guardian sessions", %{
    conn: conn
  } do
    endpoint = GSMLG.AdminWeb.Endpoint
    config = Application.get_env(:gsmlg_admin_web, endpoint, [])

    Application.put_env(
      :gsmlg_admin_web,
      endpoint,
      Keyword.put(config, :client_certificate_auth, false)
    )

    user = user_fixture()

    conn =
      conn
      |> put_guardian_session(user, "client_certificate", String.duplicate("a", 64))
      |> put_private(:live_view_connect_info, %{x_headers: []})

    assert {:ok, _view, html} = live(conn, ~p"/gao_notes")
    assert html =~ ~s(data-admin-sign-out="true")
  end

  defp certificate_conn(conn) do
    user = user_fixture()
    certificate = client_certificate()
    assert {:ok, _binding} = bind_certificate(user, certificate)

    conn =
      conn
      |> put_guardian_session(user, "client_certificate", certificate.fingerprint)
      |> put_client_certificate_headers(certificate)

    {conn, user, certificate}
  end

  defp bind_certificate(user, certificate) do
    Accounts.bind_user_client_certificate(user, %{
      certificate_der: certificate.certificate_der,
      subject: certificate.subject,
      email: certificate.email
    })
  end

  defp put_guardian_session(conn, user, method, fingerprint \\ nil) do
    {:ok, token, _claims} = Guardian.encode_and_sign(user, %{}, token_type: "access")

    conn
    |> Plug.Test.init_test_session(%{})
    |> put_session(:guardian_default_token, token)
    |> put_session(ClientCertificateAuth.auth_method_key(), method)
    |> maybe_put_fingerprint(fingerprint)
  end

  defp maybe_put_fingerprint(conn, nil), do: conn

  defp maybe_put_fingerprint(conn, fingerprint) do
    put_session(conn, ClientCertificateAuth.fingerprint_key(), fingerprint)
  end

  defp put_live_session(conn, key, value) do
    private = Map.update!(conn.private, :plug_session, &Map.put(&1, key, value))
    %{conn | private: private}
  end

  defp assert_certificate_expired(result) do
    assert {:error, {:redirect, %{to: "/sign_in", status: 302, flash: flash}}} = result

    assert %{"error" => "Client certificate authentication expired."} =
             Phoenix.LiveView.Utils.verify_flash(GSMLG.AdminWeb.Endpoint, flash)
  end
end
