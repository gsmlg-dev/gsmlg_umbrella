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
      |> redirect(to: ~p"/users/#{user.id}")
    else
      # No user
      changeset = Auth.sign_in_changeset(%Auth{}, %{})

      conn
      |> put_layout({GSMLGWeb.Layouts, :auth})
      |> render(:sign_in, changeset: changeset, page_title: "SIGN IN")
    end
  end

  def sign_in(conn, %{"auth" => params}) do
    case Auth.sign_in(params) do
      {:ok, %User{} = user} ->
        # Use access tokens.
        # Other tokens can be used, like :refresh etc
        conn
        |> put_flash(:info, "Sign in successfully.")
        |> Guardian.Plug.sign_in(user)
        |> redirect(to: ~p"/users/#{user.id}")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_flash(:error, "invalid")
        |> put_layout({GSMLGWeb.Layouts, :auth})
        |> render(:sign_in, changeset: changeset, page_title: "SIGN IN")
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
    |> put_layout({GSMLGWeb.Layouts, :auth})
    |> render("sign_up.html", changeset: changeset, page_title: "SIGN UP")
  end

  def sign_up(conn, %{"auth" => params}) do
    case(
      {Mix.env(),
       Application.get_env(:gsmlg_web, GSMLGWeb.Endpoint) |> Keyword.get(:user_register)}
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
            |> put_layout({GSMLGWeb.Layouts, :auth})
            |> render("sign_up.html", changeset: changeset, page_title: "SIGN UP")
        end
    end
  end

  def sign_up(conn, params) do
    case(
      {Mix.env(),
       Application.get_env(:gsmlg_web, GSMLGWeb.Endpoint) |> Keyword.get(:user_register)}
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
    conn
    |> Guardian.Plug.sign_out()
    |> redirect(to: ~p"/sign_in")
  end
end
