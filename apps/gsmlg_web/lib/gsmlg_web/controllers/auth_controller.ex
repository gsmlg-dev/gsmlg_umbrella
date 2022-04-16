defmodule GSMLGWeb.AuthController do
  use GSMLGWeb, :controller

  alias GSMLG.Accounts.Auth
  alias GSMLG.Accounts.User
  alias GSMLGWeb.Guardian

  def index(conn, _params) do
    if Guardian.Plug.authenticated?(conn) do
      user = Guardian.Plug.current_resource(conn)

      conn
      |> put_flash(:info, "Auth created successfully.")
      |> redirect(to: Routes.user_show_path(conn, :show, user))
    else
      # No user
      changeset = Auth.sign_in_changeset(%Auth{}, %{})

      conn
      |> put_root_layout(false)
      |> put_layout("auth.html")
      |> render("sign_in.html", changeset: changeset)
    end
  end

  def sign_in(conn, %{"auth" => params}) do
    IO.inspect(params)

    case Auth.sign_in(params) do
      {:ok, %User{} = user} ->
        # Use access tokens.
        # Other tokens can be used, like :refresh etc
        conn
        |> put_flash(:info, "Sign in successfully.")
        |> Guardian.Plug.sign_in(user)
        |> redirect(to: Routes.user_show_path(conn, :show, user))

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_flash(:error, "invalid")
        |> put_root_layout(false)
        |> put_layout("auth.html")
        |> render("sign_in.html", changeset: changeset)
    end
  end

  def sign_in(conn, params) do
    case Auth.sign_in(params) do
      {:ok, %User{} = user} ->
        # Use access tokens.
        # Other tokens can be used, like :refresh etc
        conn
        |> render("sign_in.json", username: user.username, token: Guardian.encode_and_sign(user))

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> render("error.json", changeset: changeset)
    end
  end

  def new(conn, _params) do
    changeset = Auth.sign_up_changeset(%Auth{}, %{})

    conn
    |> put_root_layout(false)
    |> put_layout("auth.html")
    |> render("sign_up.html", changeset: changeset)
  end

  def sign_up(conn, %{"auth" => params}) do
    case Auth.sign_up(params) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Auth created successfully.")
        |> redirect(to: Routes.auth_path(conn, :index))

      {:error, %Ecto.Changeset{} = changeset} ->
        IO.inspect(changeset)

        conn
        |> put_flash(:error, "invalid")
        |> put_root_layout(false)
        |> put_layout("auth.html")
        |> render("sign_up.html", changeset: changeset)
    end
  end

  def sign_up(conn, params) do
    case Auth.sign_up(params) do
      {:ok, user} ->
        conn
        |> render("sign_up.json", username: user.username)

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> render("error.json", changeset: changeset)
    end
  end

  def sign_out(conn, _params) do
    conn
    |> Guardian.Plug.sign_out()
    |> redirect(to: Routes.auth_path(conn, :index))
  end
end
