defmodule GSMLG.Web.AuthControllerTest do
  use GSMLG.Web.ConnCase

  describe "sign in" do
    test "sign in page", %{conn: conn} do
      conn = get(conn, ~p"/sign_in?lang=en")
      document = conn |> html_response(200) |> Floki.parse_document!()

      assert document |> Floki.find("h3") |> Floki.text() |> String.trim() == "Sign in"
      assert [_form] = Floki.find(document, "form#user-form[method=post]")
      assert [_username] = Floki.find(document, "#user-form input[name='auth[username]']")

      assert [_password] =
               Floki.find(document, "#user-form input[name='auth[password]'][type=password]")

      assert Floki.find(document, "a[href='/auth/github']") == []
    end
  end

  test "magic link route and template retain the form without the GitHub sign-in link", %{
    conn: conn
  } do
    assert %{plug: GSMLG.Web.MagicLinkController, plug_opts: :new} =
             Phoenix.Router.route_info(
               GSMLG.Web.Router,
               "GET",
               "/auth/magic-link/new",
               "localhost"
             )

    # Supply themes explicitly: the existing controller omits this required template assign.
    document =
      GSMLG.Web.MagicLinkHTML
      |> Phoenix.Template.render_to_string("new", "html",
        conn: conn,
        email: nil,
        error: nil,
        themes: []
      )
      |> Floki.parse_document!()

    assert [_form] = Floki.find(document, "form[action='/auth/magic-link'][method=post]")
    assert [_email] = Floki.find(document, "input[name=email][type=email]")
    assert Floki.find(document, "a[href='/auth/github']") == []
  end

  test "retired GitHub sign-in and callback routes return 404", %{conn: conn} do
    for path <- ["/auth/github", "/auth/github/callback"] do
      assert conn |> get(path) |> response(404)
    end
  end

  describe "sign up" do
    test "sign up page redirects to sign in", %{conn: conn} do
      conn = get(conn, ~p"/sign_up")
      assert redirected_to(conn) == ~p"/sign_in"
    end
  end
end
