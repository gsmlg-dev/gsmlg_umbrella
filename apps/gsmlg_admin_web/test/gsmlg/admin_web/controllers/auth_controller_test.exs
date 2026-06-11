defmodule GSMLG.AdminWeb.AuthControllerTest do
  use GSMLG.AdminWeb.ConnCase

  import GSMLG.AccountsFixtures

  @create_attrs %{}
  @update_attrs %{}
  @invalid_attrs %{}

  describe "index" do
    test "lists all users", %{conn: conn} do
      conn = get(conn, ~p"/sign_in")
      assert html_response(conn, 200) =~ "SIGN IN"
    end

    test "includes a DuskMoon theme on the html root", %{conn: conn} do
      conn = get(conn, ~p"/sign_in")
      assert html_response(conn, 200) =~ ~s(<html lang="en" data-theme="sunshine">)
    end
  end

  describe "new auth" do
    test "renders form", %{conn: conn} do
      conn = get(conn, ~p"/sign_up")
      assert html_response(conn, 200) =~ "SIGN UP"
    end
  end

  defp create_user(_) do
    user = user_fixture()
    %{user: user}
  end
end
