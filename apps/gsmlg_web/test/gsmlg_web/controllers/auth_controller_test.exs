defmodule GSMLGWeb.AuthControllerTest do
  use GSMLGWeb.ConnCase

  import GSMLG.AccountsFixtures

  @create_attrs %{}
  @update_attrs %{}
  @invalid_attrs %{}

  describe "index" do
    test "lists all users", %{conn: conn} do
      conn = get(conn, ~p"/sign_in")
      assert html_response(conn, 200) =~ "SIGN IN"
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
