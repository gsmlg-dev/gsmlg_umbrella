defmodule GSMLG.AdminWeb.AuthControllerTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import GSMLG.AccountsFixtures
  import GSMLG.AdminWeb.ClientCertificateFixtures

  alias GSMLG.Accounts
  alias GSMLG.Accounts.UserClientCertificate
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

  describe "index" do
    test "lists all users", %{conn: conn} do
      conn = get(conn, ~p"/sign_in")
      assert html_response(conn, 200) =~ "SIGN IN"
    end

    test "includes a DuskMoon theme on the html root", %{conn: conn} do
      conn = get(conn, ~p"/sign_in")
      assert html_response(conn, 200) =~ ~s(<html lang="en" data-theme="sunshine">)
    end

    test "renders unbound certificate enrollment without form certificate fields", %{conn: conn} do
      certificate = client_certificate(%{email: "display-only@example.test"})

      conn = conn |> put_client_certificate_headers(certificate) |> get(~p"/sign_in")
      html = html_response(conn, 200)
      {:ok, document} = Floki.parse_document(html)

      assert Floki.find(document, "#client-certificate-enrollment") != []

      assert Floki.text(Floki.find(document, "#client-certificate-subject")) =~
               certificate.subject

      assert Floki.text(Floki.find(document, "#client-certificate-email")) =~ certificate.email
      assert [{"textarea", attrs, [pem]}] = Floki.find(document, "#client-certificate-pem")
      assert {"readonly", "readonly"} in attrs
      assert {"spellcheck", "false"} in attrs
      assert {"wrap", "off"} in attrs
      assert {"rows", "8"} in attrs
      refute Enum.any?(attrs, fn {name, _value} -> name == "name" end)
      assert pem == certificate.pem

      assert [{"section", section_attrs, _children}] =
               Floki.find(document, "#client-certificate-enrollment")

      assert {"aria-labelledby", "client-certificate-enrollment-title"} in section_attrs

      assert [{"input", username_attrs, _children}] =
               Floki.find(document, ~s(input[name="auth[username]"]))

      assert {"aria-describedby", "client-certificate-notice"} in username_attrs
      refute Enum.any?(username_attrs, fn {name, _value} -> name == "autofocus" end)
      assert Floki.find(document, "#client-certificate-notice") != []
      assert html =~ "permanently binds this certificate"
      refute html =~ certificate.der_base64
      refute html =~ ~s(name="certificate)
    end

    test "password-only form has no certificate panel", %{conn: conn} do
      html = conn |> get(~p"/sign_in") |> html_response(200)
      {:ok, document} = Floki.parse_document(html)

      assert Floki.find(document, "#client-certificate-enrollment") == []

      assert [{"input", attrs, _children}] =
               Floki.find(document, ~s(input[name="auth[username]"]))

      assert {"autofocus", "autofocus"} in attrs
      refute Enum.any?(attrs, fn {name, _value} -> name == "aria-describedby" end)
    end

    test "disabled certificate authentication ignores certificate headers", %{conn: conn} do
      endpoint = GSMLG.AdminWeb.Endpoint
      config = Application.get_env(:gsmlg_admin_web, endpoint, [])

      Application.put_env(
        :gsmlg_admin_web,
        endpoint,
        Keyword.put(config, :client_certificate_auth, false)
      )

      certificate = client_certificate()

      html =
        conn
        |> put_client_certificate_headers(certificate)
        |> get(~p"/sign_in")
        |> html_response(200)

      refute html =~ "client-certificate-enrollment"
      refute html =~ certificate.subject
      refute html =~ certificate.pem
    end
  end

  describe "sign in" do
    test "failed credentials preserve certificate display and create no binding", %{conn: conn} do
      user = user_fixture()
      certificate = client_certificate()

      conn =
        conn
        |> put_client_certificate_headers(certificate)
        |> post(~p"/sign_in", %{
          "auth" => %{"username" => user.username, "password" => "incorrect password"}
        })

      html = html_response(conn, 200)
      assert html =~ certificate.subject
      assert html =~ certificate.pem
      assert Accounts.get_user_client_certificate_by_fingerprint(certificate.fingerprint) == nil
      assert get_session(conn, :guardian_default_token) == nil
      assert get_session(conn, ClientCertificateAuth.auth_method_key()) == nil
      assert get_session(conn, ClientCertificateAuth.fingerprint_key()) == nil
    end

    test "successful password login binds certificate despite unrelated display email", %{
      conn: conn
    } do
      user = user_fixture(%{email: "account@example.test"})
      certificate = client_certificate(%{email: "certificate@example.test"})

      conn =
        conn
        |> put_client_certificate_headers(certificate)
        |> post(~p"/sign_in", %{
          "auth" => %{"username" => user.username, "password" => "some password"}
        })

      assert redirected_to(conn) == ~p"/users/#{user.id}"

      assert Accounts.get_user_client_certificate_by_fingerprint(certificate.fingerprint).user_id ==
               user.id

      assert get_session(conn, ClientCertificateAuth.auth_method_key()) == "client_certificate"
      assert get_session(conn, ClientCertificateAuth.fingerprint_key()) == certificate.fingerprint
      assert Guardian.Plug.current_resource(conn).id == user.id
    end

    test "successful enrollment telemetry excludes certificate identity fields", %{conn: conn} do
      user = user_fixture()

      certificate =
        client_certificate(%{
          subject: "CN=private-subject-#{System.unique_integer([:positive])}",
          email: "private-certificate-#{System.unique_integer([:positive])}@example.test"
        })

      %{level: previous_log_level} = :logger.get_primary_config()

      {conn, log} =
        try do
          Logger.configure(level: :info)

          with_log([level: :info], fn ->
            conn
            |> put_client_certificate_headers(certificate)
            |> post(~p"/sign_in", %{
              "auth" => %{"username" => user.username, "password" => "some password"}
            })
          end)
        after
          Logger.configure(level: previous_log_level)
        end

      assert redirected_to(conn) == ~p"/users/#{user.id}"
      assert log =~ "Admin client certificate bound"
      assert log =~ "user_id=#{inspect(user.id)}"
      assert log =~ "fingerprint=#{inspect(certificate.fingerprint)}"
      refute log =~ certificate.subject
      refute log =~ certificate.email
    end

    test "ordinary password login records password method and creates no certificate binding", %{
      conn: conn
    } do
      user = user_fixture()

      conn =
        post(conn, ~p"/sign_in", %{
          "auth" => %{"username" => user.username, "password" => "some password"}
        })

      assert redirected_to(conn) == ~p"/users/#{user.id}"
      assert get_session(conn, ClientCertificateAuth.auth_method_key()) == "password"
      assert get_session(conn, ClientCertificateAuth.fingerprint_key()) == nil
      assert GSMLG.Repo.aggregate(UserClientCertificate, :count) == 0
    end

    test "already-bound certificate ignores another user's submitted credentials", %{conn: conn} do
      owner = user_fixture(%{username: "bound_owner", email: "bound-owner@example.test"})
      other = user_fixture(%{username: "submitted_user", email: "submitted@example.test"})
      certificate = client_certificate()
      assert {:ok, _binding} = bind_certificate(owner, certificate)

      conn =
        conn
        |> put_client_certificate_headers(certificate)
        |> post(~p"/sign_in", %{
          "auth" => %{"username" => other.username, "password" => "some password"}
        })

      assert redirected_to(conn) == ~p"/users/#{owner.id}"
      assert Guardian.Plug.current_resource(conn).id == owner.id
      assert get_session(conn, ClientCertificateAuth.auth_method_key()) == "client_certificate"
    end
  end

  describe "sign out" do
    test "certificate-authenticated sign-out keeps its owner and token signed in", %{conn: conn} do
      owner = user_fixture()
      certificate = client_certificate()
      assert {:ok, _binding} = bind_certificate(owner, certificate)

      request =
        conn
        |> put_guardian_session(owner, "client_certificate")
        |> put_session(ClientCertificateAuth.fingerprint_key(), certificate.fingerprint)
        |> put_client_certificate_headers(certificate)

      existing_token = get_session(request, :guardian_default_token)
      conn = delete(request, ~p"/sign_out")

      assert redirected_to(conn) == ~p"/users/#{owner.id}"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "Remove the client certificate to end certificate access."

      assert get_session(conn, :guardian_default_token) == existing_token
      assert Guardian.Plug.current_resource(conn).id == owner.id
    end

    test "password-authenticated sign-out clears token and certificate markers", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> put_guardian_session(user, "password")
        |> put_session(ClientCertificateAuth.fingerprint_key(), String.duplicate("a", 64))
        |> delete(~p"/sign_out")

      assert redirected_to(conn) == ~p"/sign_in"
      assert get_session(conn, :guardian_default_token) == nil
      assert get_session(conn, ClientCertificateAuth.auth_method_key()) == nil
      assert get_session(conn, ClientCertificateAuth.fingerprint_key()) == nil
    end
  end

  test "bound certificate protected page exposes auth method and stable sign-out id", %{
    conn: conn
  } do
    owner = user_fixture()
    certificate = client_certificate()
    assert {:ok, _binding} = bind_certificate(owner, certificate)

    html =
      conn
      |> put_client_certificate_headers(certificate)
      |> get(~p"/")
      |> html_response(200)

    assert html =~ ~s(data-admin-auth-method="client_certificate")
    assert html =~ ~s(id="admin-sign-out")
  end

  describe "new auth" do
    test "renders form", %{conn: conn} do
      conn = get(conn, ~p"/sign_up")
      assert html_response(conn, 200) =~ "SIGN UP"
    end
  end

  defp bind_certificate(user, fixture) do
    Accounts.bind_user_client_certificate(user, %{
      certificate_der: fixture.certificate_der,
      subject: fixture.subject,
      email: fixture.email
    })
  end

  defp put_guardian_session(conn, user, method) do
    {:ok, token, _claims} = Guardian.encode_and_sign(user, %{}, token_type: "access")

    conn
    |> Plug.Test.init_test_session(%{})
    |> put_session(:guardian_default_token, token)
    |> put_session(ClientCertificateAuth.auth_method_key(), method)
  end
end
