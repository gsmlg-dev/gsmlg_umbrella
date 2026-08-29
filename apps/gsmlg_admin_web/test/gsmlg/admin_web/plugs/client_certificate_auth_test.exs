defmodule GSMLG.AdminWeb.Plugs.ClientCertificateAuthTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import GSMLG.AccountsFixtures
  import GSMLG.AdminWeb.ClientCertificateFixtures

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

  test "bound certificate opens a protected browser route", %{conn: conn} do
    user = user_fixture()
    certificate = client_certificate()
    assert {:ok, _binding} = bind_certificate(user, certificate)

    conn =
      conn
      |> put_client_certificate_headers(certificate)
      |> get(~p"/")

    assert html_response(conn, 200)
    assert get_session(conn, ClientCertificateAuth.auth_method_key()) == "client_certificate"

    assert get_session(conn, ClientCertificateAuth.fingerprint_key()) ==
             certificate.fingerprint

    assert conn.assigns.admin_auth_method == "client_certificate"
    assert conn.assigns.client_certificate.fingerprint == certificate.fingerprint
    assert conn.assigns.client_certificate.certificate_der == certificate.certificate_der
    assert ClientCertificateAuth.certificate_authenticated?(conn)
  end

  test "bound certificate replaces a different password user", %{conn: conn} do
    owner = user_fixture(%{username: "cert_owner", email: "owner@example.test"})
    other = user_fixture(%{username: "password_user", email: "password@example.test"})
    certificate = client_certificate()
    assert {:ok, _binding} = bind_certificate(owner, certificate)

    conn =
      conn
      |> put_guardian_session(other)
      |> put_client_certificate_headers(certificate)
      |> get(~p"/")

    token = get_session(conn, :guardian_default_token)

    assert {:ok, resource, _claims} =
             Guardian.resource_from_token(GSMLG.AdminWeb.Guardian, token)

    assert resource.id == owner.id
    assert get_session(conn, ClientCertificateAuth.auth_method_key()) == "client_certificate"
  end

  test "bound certificate preserves the same owner's token", %{conn: conn} do
    user = user_fixture()
    certificate = client_certificate()
    assert {:ok, _binding} = bind_certificate(user, certificate)

    conn = put_guardian_session(conn, user)
    existing_token = get_session(conn, :guardian_default_token)

    conn =
      conn
      |> put_client_certificate_headers(certificate)
      |> get(~p"/")

    assert html_response(conn, 200)
    assert get_session(conn, :guardian_default_token) == existing_token
    assert get_session(conn, ClientCertificateAuth.auth_method_key()) == "client_certificate"

    assert get_session(conn, ClientCertificateAuth.fingerprint_key()) ==
             certificate.fingerprint
  end

  test "valid unbound certificate clears a password session for enrollment", %{conn: conn} do
    user = user_fixture()
    certificate = client_certificate()

    conn =
      conn
      |> put_guardian_session(user)
      |> put_client_certificate_headers(certificate)
      |> get(~p"/")

    assert redirected_to(conn) == ~p"/sign_in"
    assert get_session(conn, :guardian_default_token) == nil
    assert get_session(conn, ClientCertificateAuth.auth_method_key()) == nil
    assert get_session(conn, ClientCertificateAuth.fingerprint_key()) == nil
    assert conn.assigns.admin_auth_method == nil
    assert conn.assigns.client_certificate.fingerprint == certificate.fingerprint
    assert conn.assigns.client_certificate.certificate_der == certificate.certificate_der
    refute ClientCertificateAuth.certificate_authenticated?(conn)
  end

  test "missing certificate clears a certificate-created session", %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> put_guardian_session(user, "client_certificate")
      |> put_session(ClientCertificateAuth.fingerprint_key(), String.duplicate("a", 64))
      |> get(~p"/")

    assert redirected_to(conn) == ~p"/sign_in"
    assert get_session(conn, :guardian_default_token) == nil
    assert get_session(conn, ClientCertificateAuth.auth_method_key()) == nil
    assert get_session(conn, ClientCertificateAuth.fingerprint_key()) == nil
    assert conn.assigns.admin_auth_method == nil
  end

  test "malformed certificate clears a certificate-created session", %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> put_guardian_session(user, "client_certificate")
      |> put_session(ClientCertificateAuth.fingerprint_key(), String.duplicate("a", 64))
      |> put_malformed_client_certificate_headers()
      |> get(~p"/")

    assert redirected_to(conn) == ~p"/sign_in"
    assert get_session(conn, :guardian_default_token) == nil
    assert get_session(conn, ClientCertificateAuth.auth_method_key()) == nil
    assert get_session(conn, ClientCertificateAuth.fingerprint_key()) == nil
    assert conn.assigns.admin_auth_method == nil
  end

  test "missing and malformed certificates preserve a password session" do
    user = user_fixture()

    for add_headers <- [fn conn -> conn end, &put_malformed_client_certificate_headers/1] do
      request =
        build_conn()
        |> put_guardian_session(user)

      existing_token = get_session(request, :guardian_default_token)

      response =
        request
        |> add_headers.()
        |> get(~p"/")

      assert html_response(response, 200)
      assert get_session(response, :guardian_default_token) == existing_token
      assert get_session(response, ClientCertificateAuth.auth_method_key()) == "password"
      assert response.assigns.admin_auth_method == "password"
    end
  end

  test "disabled feature ignores a bound certificate without an existing cookie", %{conn: conn} do
    endpoint = GSMLG.AdminWeb.Endpoint
    config = Application.get_env(:gsmlg_admin_web, endpoint, [])

    Application.put_env(
      :gsmlg_admin_web,
      endpoint,
      Keyword.put(config, :client_certificate_auth, false)
    )

    user = user_fixture()
    certificate = client_certificate()
    assert {:ok, _binding} = bind_certificate(user, certificate)
    assert get_req_header(conn, "cookie") == []

    conn =
      conn
      |> put_client_certificate_headers(certificate)
      |> get(~p"/")

    assert redirected_to(conn) == ~p"/sign_in"
    assert get_session(conn, :guardian_default_token) == nil
    refute Map.has_key?(conn.assigns, :client_certificate)
    refute Map.has_key?(conn.assigns, :admin_auth_method)
  end

  defp bind_certificate(user, fixture) do
    GSMLG.Accounts.bind_user_client_certificate(user, %{
      certificate_der: fixture.certificate_der,
      subject: fixture.subject,
      email: fixture.email
    })
  end

  defp put_guardian_session(conn, user, method \\ "password") do
    {:ok, token, _claims} =
      GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

    conn
    |> Plug.Test.init_test_session(%{})
    |> put_session(:guardian_default_token, token)
    |> put_session(ClientCertificateAuth.auth_method_key(), method)
  end

  defp put_malformed_client_certificate_headers(conn) do
    conn
    |> put_req_header("x-client-cert-subject", "CN=malformed.example.test")
    |> put_req_header("x-client-cert-certificate-pem", "not-base64")
    |> put_req_header("x-client-cert-email", "malformed@example.test")
  end
end
