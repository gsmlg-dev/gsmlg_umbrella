defmodule GSMLG.AdminWeb.AuthController do
  use GSMLG.AdminWeb, :controller

  alias GSMLG.Accounts
  alias GSMLG.Accounts.Auth
  alias GSMLG.Accounts.User
  alias GSMLG.AdminWeb.Guardian
  alias GSMLG.AdminWeb.Plugs.ClientCertificateAuth

  def index(conn, _params) do
    if Guardian.Plug.authenticated?(conn) do
      user = Guardian.Plug.current_resource(conn)

      conn
      |> put_flash(:info, "Auth created successfully.")
      |> redirect(to: ~p"/users/#{user.id}")
    else
      # No user
      changeset = Auth.sign_in_changeset(%Auth{}, %{})

      render_sign_in(conn, changeset)
    end
  end

  def sign_in(conn, %{"auth" => params}) do
    if ClientCertificateAuth.certificate_authenticated?(conn) do
      user = Guardian.Plug.current_resource(conn)
      redirect(conn, to: ~p"/users/#{user.id}")
    else
      case Auth.sign_in(params) do
        {:ok, %User{} = user} ->
          complete_html_sign_in(conn, user)

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_flash(:error, "invalid")
          |> render_sign_in(changeset)
      end
    end
  end

  def sign_in(conn, params) do
    case Auth.sign_in(params) do
      {:ok, %User{} = user} ->
        # Use access tokens.
        # Other tokens can be used, like :refresh etc
        conn
        |> render("sign_in.json",
          layout: false,
          username: user.username,
          token: Guardian.encode_and_sign(user)
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> render("error.json", changeset: changeset)
    end
  end

  def new(conn, _params) do
    changeset = Auth.sign_up_changeset(%Auth{}, %{})

    conn
    |> render(:sign_up, changeset: changeset, page_title: "SIGN UP")
  end

  def sign_up(conn, %{"auth" => params}) do
    case(
      {Mix.env(),
       Application.get_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint)
       |> Keyword.get(:user_register)}
    ) do
      {:prod, false} ->
        conn
        |> put_flash(:error, "Not Allowed")
        |> redirect(to: ~p"/sign_in")

      _ ->
        case Auth.sign_up(params) do
          {:ok, _user} ->
            conn
            |> put_flash(:info, "Auth created successfully.")
            |> redirect(to: ~p"/sign_in")

          {:error, %Ecto.Changeset{} = changeset} ->
            conn
            |> put_flash(:error, "invalid")
            |> render(:sign_up, changeset: changeset, page_title: "SIGN UP")
        end
    end
  end

  def sign_up(conn, params) do
    case(
      {Mix.env(),
       Application.get_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint)
       |> Keyword.get(:user_register)}
    ) do
      {:prod, false} ->
        conn
        |> render("error.json", errors: ["Not Allowed"])

      _ ->
        case Auth.sign_up(params) do
          {:ok, user} ->
            conn
            |> render("sign_up.json", username: user.username)

          {:error, %Ecto.Changeset{} = changeset} ->
            conn
            |> render("error.json", changeset: changeset)
        end
    end
  end

  def sign_out(conn, _params) do
    if Phoenix.Controller.get_format(conn) == "html" and
         ClientCertificateAuth.certificate_authenticated?(conn) do
      user = Guardian.Plug.current_resource(conn)

      conn
      |> put_flash(:info, "Remove the client certificate to end certificate access.")
      |> redirect(to: ~p"/users/#{user.id}")
    else
      conn
      |> Guardian.Plug.sign_out()
      |> delete_session(ClientCertificateAuth.auth_method_key())
      |> delete_session(ClientCertificateAuth.fingerprint_key())
      |> redirect(to: ~p"/sign_in")
    end
  end

  defp render_sign_in(conn, changeset, opts \\ []) do
    conn
    |> put_status(Keyword.get(opts, :status, :ok))
    |> render(:sign_in,
      changeset: changeset,
      client_certificate: conn.assigns[:client_certificate],
      page_title: "SIGN IN"
    )
  end

  defp complete_html_sign_in(conn, user) do
    case conn.assigns[:client_certificate] do
      nil ->
        conn
        |> put_flash(:info, "Sign in successfully.")
        |> ClientCertificateAuth.sign_in_with_password(user)
        |> redirect(to: ~p"/users/#{user.id}")

      certificate ->
        bind_client_certificate(conn, user, certificate)
    end
  end

  defp bind_client_certificate(conn, user, certificate) do
    case Accounts.bind_user_client_certificate(user, %{
           certificate_der: certificate.certificate_der,
           subject: certificate.subject,
           email: certificate.email
         }) do
      {:ok, _binding} ->
        GSMLG.Telemetry.info("Admin client certificate bound",
          metadata: %{
            user_id: user.id,
            fingerprint: certificate.fingerprint
          }
        )

        conn
        |> put_flash(:info, "Certificate bound and signed in successfully.")
        |> ClientCertificateAuth.sign_in_with_certificate(user, certificate)
        |> redirect(to: ~p"/users/#{user.id}")

      {:error, {:client_certificate_already_bound, owner_user_id}} ->
        GSMLG.Telemetry.warn("Admin client certificate binding conflict",
          metadata: %{
            attempted_user_id: user.id,
            owner_user_id: owner_user_id,
            fingerprint: certificate.fingerprint
          }
        )

        conn
        |> put_flash(:error, "This certificate is already bound to another user.")
        |> render_sign_in(Auth.sign_in_changeset(%Auth{}, %{}), status: :conflict)

      {:error, reason} ->
        GSMLG.Telemetry.warn("Admin client certificate binding failed",
          metadata: %{
            user_id: user.id,
            fingerprint: certificate.fingerprint,
            reason: certificate_binding_failure_category(reason)
          }
        )

        conn
        |> put_flash(:error, "The certificate could not be bound. Please try again.")
        |> render_sign_in(Auth.sign_in_changeset(%Auth{}, %{}), status: :unprocessable_entity)
    end
  end

  defp certificate_binding_failure_category(%Ecto.Changeset{}), do: :validation_failed

  defp certificate_binding_failure_category(:client_certificate_binding_failed),
    do: :binding_failed

  defp certificate_binding_failure_category(_reason), do: :persistence_failed
end
