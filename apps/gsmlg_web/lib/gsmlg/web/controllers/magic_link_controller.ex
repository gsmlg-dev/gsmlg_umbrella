defmodule GSMLG.Web.MagicLinkController do
  use GSMLG.Web, :controller

  alias GSMLG.Accounts.MagicLink

  def new(conn, _params) do
    render(conn, :new, email: nil, error: nil)
  end

  def create(conn, %{"email" => email}) do
    case MagicLink.generate_magic_link(email) do
      {:ok, user} ->
        # Send email asynchronously
        Task.start(fn ->
          MagicLink.send_magic_link_email(user, user.magic_link_token)
        end)

        conn
        |> put_flash(:info, "Magic link sent! Check your email.")
        |> redirect(to: ~p"/auth/magic-link/sent")

      {:error, _changeset} ->
        render(conn, :new, email: email, error: "Failed to send magic link")
    end
  end

  def sent(conn, _params) do
    render(conn, :sent)
  end

  def confirm(conn, %{"token" => token}) do
    case MagicLink.validate_magic_link(token) do
      {:ok, user} ->
        # Create session for the user
        conn
        |> put_session(:user_token, generate_session_token(user))
        |> put_flash(:info, "Welcome back!")
        |> redirect(to: ~p"/")

      {:error, :invalid_or_expired_token} ->
        conn
        |> put_flash(:error, "Invalid or expired magic link. Please request a new one.")
        |> redirect(to: ~p"/auth/magic-link/new")
    end
  end

  def sudo_mode(conn, _params) do
    # Phoenix 1.8 Sudo Mode implementation
    render(conn, :sudo_mode)
  end

  def require_sudo_mode(conn, _params) do
    # Check if user authenticated within recent time window
    last_auth = get_session(conn, :last_authenticated_at)

    if last_auth && DateTime.from_iso8601(last_auth) > DateTime.add(DateTime.utc_now(), -15, :minute) do
      conn
    else
      conn
      |> put_session(:return_to, conn.request_path)
      |> redirect(to: ~p"/auth/sudo-mode")
      |> halt()
    end
  end

  defp generate_session_token(_user) do
    # Generate a secure session token
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64()
    |> binary_part(0, 32)
  end
end