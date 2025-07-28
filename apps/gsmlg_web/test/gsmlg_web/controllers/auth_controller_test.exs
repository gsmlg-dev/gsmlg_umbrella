defmodule GSMLGWeb.AuthControllerTest do
  use GSMLGWeb.ConnCase

  describe "sign in" do
    test "sign in page", %{conn: conn} do
      conn = get(conn, ~p"/sign_in")
      assert html_response(conn, 200) =~ "SIGN IN"
    end
  end

  describe "sign up" do
    test "sign up page redirects to sign in", %{conn: conn} do
      conn = get(conn, ~p"/sign_up")
      assert redirected_to(conn) == ~p"/sign_in"
    end
  end
end
