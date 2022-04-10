defmodule GSMLGWeb.AuthController do
  use GSMLGWeb, :controller

  alias GSMLG.Accounts.Auth
  alias GSMLG.Accounts.User

  def index(conn, _params) do
    if Guardian.Plug.authenticated?(conn) do
      user = Guardian.Plug.current_resource(conn)
    else
      # No user
    end

    render(conn, "index.html")
  end

  def new(conn, params) do
    changeset = Auth.changeset(%User{}, params)
    render(conn, "new.html", changeset: changeset)
  end

  def create(conn, %{"auth" => auth_params}) do
    case Auth.sign_up(auth_params) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Auth created successfully.")
        |> redirect(to: Routes.user_show_path(conn, :show, user))

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, "new.html", changeset: changeset)
    end
  end

  def sign_in(conn, params) do
    case Auth.sign_in(params) do
      {:ok, user} ->
        # Use access tokens.
        # Other tokens can be used, like :refresh etc
        conn
        |> Guardian.Plug.sign_in(user, :access)
        |> render("index.html")

      {:ok, user, api} ->
        {:ok, jwt, _claims} = Guardian.encode_and_sign(user, :access)
        conn |> render("index.html", %{token: jwt})

      {:error, _reason} ->
        nil
        # handle not verifying the user's credentials
    end
  end

  def sign_out(conn, params) do
    conn
    |> Guardian.Plug.sign_out(params)
    |> render("index.html", %{})
  end
end
