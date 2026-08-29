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

  test "bound certificate replaces a malformed Guardian session without redirecting", %{
    conn: conn
  } do
    owner = user_fixture()
    certificate = client_certificate()
    assert {:ok, _binding} = bind_certificate(owner, certificate)

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> put_session(:guardian_default_token, "malformed-token")
      |> put_client_certificate_headers(certificate)
      |> get(~p"/")

    assert html_response(conn, 200)
    assert get_resp_header(conn, "location") == []

    token = get_session(conn, :guardian_default_token)

    assert {:ok, resource, %{"typ" => "access"}} =
             Guardian.resource_from_token(GSMLG.AdminWeb.Guardian, token)

    assert resource.id == owner.id
  end

  test "bound certificate replaces a different password user", %{conn: conn} do
    owner = user_fixture(%{username: "cert_owner", email: "owner@example.test"})
    other = user_fixture(%{username: "password_user", email: "password@example.test"})
    certificate = client_certificate()
    assert {:ok, _binding} = bind_certificate(owner, certificate)

    request =
      conn
      |> put_guardian_session(other)
      |> put_client_certificate_headers(certificate)

    old_token = get_session(request, :guardian_default_token)
    conn = get(request, ~p"/")
    new_token = get_session(conn, :guardian_default_token)

    refute new_token == old_token

    assert {:ok, resource, %{"typ" => "access"}} =
             Guardian.resource_from_token(GSMLG.AdminWeb.Guardian, new_token)

    assert resource.id == owner.id
    assert get_session(conn, ClientCertificateAuth.auth_method_key()) == "client_certificate"
    assert_revoked(old_token)
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

  test "bound certificate rotates the same owner's non-access token", %{conn: conn} do
    user = user_fixture()
    certificate = client_certificate()
    assert {:ok, _binding} = bind_certificate(user, certificate)

    request = put_guardian_session(conn, user, "password", "refresh")
    refresh_token = get_session(request, :guardian_default_token)

    conn =
      request
      |> put_client_certificate_headers(certificate)
      |> get(~p"/")

    access_token = get_session(conn, :guardian_default_token)
    refute access_token == refresh_token

    assert {:ok, resource, %{"typ" => "access"}} =
             Guardian.resource_from_token(GSMLG.AdminWeb.Guardian, access_token)

    assert resource.id == user.id
    assert_revoked(refresh_token)
  end

  test "valid unbound certificate clears a password session for enrollment", %{conn: conn} do
    user = user_fixture()
    certificate = client_certificate()

    request =
      conn
      |> put_guardian_session(user)
      |> put_client_certificate_headers(certificate)

    old_token = get_session(request, :guardian_default_token)
    conn = get(request, ~p"/")

    assert redirected_to(conn) == ~p"/sign_in"
    assert get_session(conn, :guardian_default_token) == nil
    assert get_session(conn, ClientCertificateAuth.auth_method_key()) == nil
    assert get_session(conn, ClientCertificateAuth.fingerprint_key()) == nil
    assert conn.assigns.admin_auth_method == nil
    assert conn.assigns.client_certificate.fingerprint == certificate.fingerprint
    assert conn.assigns.client_certificate.certificate_der == certificate.certificate_der
    refute ClientCertificateAuth.certificate_authenticated?(conn)
    assert_revoked(old_token)
  end

  test "missing certificate clears a certificate-created session", %{conn: conn} do
    user = user_fixture()

    request =
      conn
      |> put_guardian_session(user, "client_certificate")
      |> put_session(ClientCertificateAuth.fingerprint_key(), String.duplicate("a", 64))

    old_token = get_session(request, :guardian_default_token)
    conn = get(request, ~p"/")

    assert redirected_to(conn) == ~p"/sign_in"
    assert get_session(conn, :guardian_default_token) == nil
    assert get_session(conn, ClientCertificateAuth.auth_method_key()) == nil
    assert get_session(conn, ClientCertificateAuth.fingerprint_key()) == nil
    assert conn.assigns.admin_auth_method == nil
    assert_revoked(old_token)
  end

  test "malformed certificate clears a certificate-created session", %{conn: conn} do
    user = user_fixture()

    request =
      conn
      |> put_guardian_session(user, "client_certificate")
      |> put_session(ClientCertificateAuth.fingerprint_key(), String.duplicate("a", 64))
      |> put_malformed_client_certificate_headers()

    old_token = get_session(request, :guardian_default_token)
    conn = get(request, ~p"/")

    assert redirected_to(conn) == ~p"/sign_in"
    assert get_session(conn, :guardian_default_token) == nil
    assert get_session(conn, ClientCertificateAuth.auth_method_key()) == nil
    assert get_session(conn, ClientCertificateAuth.fingerprint_key()) == nil
    assert conn.assigns.admin_auth_method == nil
    assert_revoked(old_token)
  end

  test "missing and malformed certificates preserve non-certificate sessions and clear stale fingerprints" do
    user = user_fixture()

    for add_headers <- [fn conn -> conn end, &put_malformed_client_certificate_headers/1],
        method <- ["password", "legacy", nil] do
      request =
        build_conn()
        |> put_guardian_session(user, method)
        |> put_session(ClientCertificateAuth.fingerprint_key(), String.duplicate("b", 64))

      existing_token = get_session(request, :guardian_default_token)

      response =
        request
        |> add_headers.()
        |> get(~p"/")

      assert html_response(response, 200)
      assert get_session(response, :guardian_default_token) == existing_token
      assert get_session(response, ClientCertificateAuth.auth_method_key()) == method
      assert get_session(response, ClientCertificateAuth.fingerprint_key()) == nil
      assert response.assigns.admin_auth_method == method
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

  defp put_guardian_session(conn, user, method \\ "password", token_type \\ "access") do
    {:ok, token, _claims} =
      GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: token_type)

    conn
    |> Plug.Test.init_test_session(%{})
    |> put_session(:guardian_default_token, token)
    |> put_session(ClientCertificateAuth.auth_method_key(), method)
  end

  defp assert_revoked(token) do
    assert {:error, :token_not_found} =
             Guardian.resource_from_token(GSMLG.AdminWeb.Guardian, token)
  end

  defp put_malformed_client_certificate_headers(conn) do
    conn
    |> put_req_header("x-client-cert-subject", "CN=malformed.example.test")
    |> put_req_header("x-client-cert-certificate-pem", "not-base64")
    |> put_req_header("x-client-cert-email", "malformed@example.test")
  end
end
