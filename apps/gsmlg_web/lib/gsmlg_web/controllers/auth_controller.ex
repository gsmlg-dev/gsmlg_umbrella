defmodule GSMLGWeb.AuthController do
  use GSMLGWeb, :controller

  plug Ueberauth

  def callback(%{assigns: %{ueberauth_failure: %Ueberauth.Failure{}}} = conn, _params) do
    conn
    |> put_flash(:error, "Failed to authenticate")
    |> redirect(to: ~p"/")
  end

  def callback(%{assigns: %{ueberauth_auth: %Ueberauth.Auth{} = auth}} = conn, _params) do
    # You will have to implement this function that inserts into the database
    # user = GSMLG.Accounts.create_user_from_ueberauth!(auth)
    IO.inspect(auth)

    session_id = get_session(conn, :session_id)

    if Phoenix.SessionProcess.started?(session_id) do
      Phoenix.SessionProcess.cast("session_id", {:update_github, auth})
    else
      Phoenix.SessionProcess.start(session_id, GSMLG.SessionProcess, %{github: auth})
    end

    # If you are not using mix phx.gen.auth, store the user in the session
    conn
    # |> put_session(:user_id, user.id)
    |> redirect(to: ~p"/")
  end
end
