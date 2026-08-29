defmodule GSMLG.AdminWeb.Plugs.ClientCertificateAuth do
  import Plug.Conn

  alias GSMLG.Accounts
  alias GSMLG.Accounts.User
  alias GSMLG.AdminWeb.ClientCertificate
  alias GSMLG.AdminWeb.Guardian
  alias Elixir.Guardian.Plug.Keys, as: GuardianKeys

  @auth_method_key "admin_auth_method"
  @fingerprint_key "admin_client_certificate_fingerprint"

  def init(opts), do: opts

  def auth_method_key, do: @auth_method_key
  def fingerprint_key, do: @fingerprint_key

  def enabled? do
    :gsmlg_admin_web
    |> Application.get_env(GSMLG.AdminWeb.Endpoint, [])
    |> Keyword.get(:client_certificate_auth, false)
  end

  def call(conn, _opts) do
    if enabled?(), do: authenticate(conn, ClientCertificate.parse_conn(conn)), else: conn
  end

  def certificate_authenticated?(conn),
    do: conn.assigns[:client_certificate_authenticated] == true

  def sign_in_with_certificate(conn, %User{} = user, %ClientCertificate{} = certificate) do
    conn =
      case {Guardian.Plug.current_resource(conn), Guardian.Plug.current_claims(conn)} do
        {%User{id: current_id}, %{"typ" => "access"}} when current_id == user.id -> conn
        _other -> conn |> sign_out_guardian_identity() |> Guardian.Plug.sign_in(user)
      end

    conn
    |> put_session(@auth_method_key, "client_certificate")
    |> put_session(@fingerprint_key, certificate.fingerprint)
    |> assign(:admin_auth_method, "client_certificate")
    |> assign(:client_certificate, certificate)
    |> assign(:client_certificate_authenticated, true)
  end

  def sign_in_with_password(conn, %User{} = user) do
    conn
    |> Guardian.Plug.sign_in(user)
    |> put_session(@auth_method_key, "password")
    |> delete_session(@fingerprint_key)
    |> assign(:admin_auth_method, "password")
  end

  defp authenticate(conn, {:ok, certificate}) do
    case Accounts.get_user_client_certificate_by_fingerprint(certificate.fingerprint) do
      %{user: %User{} = user} -> sign_in_with_certificate(conn, user, certificate)
      nil -> prepare_enrollment(conn, certificate)
    end
  end

  defp authenticate(conn, {:error, reason}) do
    if reason != :missing_headers do
      GSMLG.Telemetry.warn("Invalid admin client certificate assertion",
        metadata: %{reason: reason}
      )
    end

    preserve_password_or_clear_certificate_session(conn)
  end

  defp prepare_enrollment(conn, certificate) do
    conn
    |> sign_out_guardian_identity()
    |> delete_session(@auth_method_key)
    |> delete_session(@fingerprint_key)
    |> assign(:admin_auth_method, nil)
    |> assign(:client_certificate, certificate)
    |> assign(:client_certificate_authenticated, false)
  end

  defp preserve_password_or_clear_certificate_session(conn) do
    if get_session(conn, @auth_method_key) == "client_certificate" do
      conn
      |> sign_out_guardian_identity()
      |> delete_session(@auth_method_key)
      |> delete_session(@fingerprint_key)
      |> assign(:admin_auth_method, nil)
    else
      conn
      |> delete_session(@fingerprint_key)
      |> assign(:admin_auth_method, get_session(conn, @auth_method_key))
    end
  end

  defp sign_out_guardian_identity(conn) do
    conn = Guardian.Plug.sign_out(conn)

    # Keep downstream unauthenticated error handling idempotent after this plug signs out.
    private =
      Map.drop(conn.private, [
        GuardianKeys.token_key(),
        GuardianKeys.claims_key(),
        GuardianKeys.resource_key()
      ])

    %{conn | private: private}
  end
end
