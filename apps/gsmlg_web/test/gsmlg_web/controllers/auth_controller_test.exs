defmodule GSMLGWeb.AuthControllerTest do
  use GSMLGWeb.ConnCase

  describe "sign in" do
    test "sign in page", %{conn: conn} do
      conn = get(conn, ~p"/sign_in")
      assert html_response(conn, 200) =~ "SIGN IN"
    end
  end

  describe "sign up" do
    test "sign up page", %{conn: conn} do
      conn = get(conn, ~p"/sign_up")
      assert html_response(conn, 200) =~ "SIGN UP"
    end
  end
end
