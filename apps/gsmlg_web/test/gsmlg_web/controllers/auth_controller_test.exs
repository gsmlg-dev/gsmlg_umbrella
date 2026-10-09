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
    end
  end

  describe "sign up" do
    test "sign up page redirects to sign in", %{conn: conn} do
      conn = get(conn, ~p"/sign_up")
      assert redirected_to(conn) == ~p"/sign_in"
    end
  end
end
