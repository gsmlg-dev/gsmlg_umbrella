defmodule GSMLGWeb.ToolboxControllerTest do
  use GSMLGWeb.ConnCase

  import GSMLG.ToolFixtures

  @create_attrs %{}
  @update_attrs %{}
  @invalid_attrs %{}

  describe "index" do
    test "lists all tools", %{conn: conn} do
      conn = get(conn, ~p"/tools")
      assert html_response(conn, 200) =~ "Listing Tools"
    end
  end

  describe "new toolbox" do
    test "renders form", %{conn: conn} do
      conn = get(conn, ~p"/tools/new")
      assert html_response(conn, 200) =~ "New Toolbox"
    end
  end

  describe "create toolbox" do
    test "redirects to show when data is valid", %{conn: conn} do
      conn = post(conn, ~p"/tools", toolbox: @create_attrs)

      assert %{id: id} = redirected_params(conn)
      assert redirected_to(conn) == ~p"/tools/#{id}"

      conn = get(conn, ~p"/tools/#{id}")
      assert html_response(conn, 200) =~ "Toolbox #{id}"
    end

    test "renders errors when data is invalid", %{conn: conn} do
      conn = post(conn, ~p"/tools", toolbox: @invalid_attrs)
      assert html_response(conn, 200) =~ "New Toolbox"
    end
  end

  describe "edit toolbox" do
    setup [:create_toolbox]

    test "renders form for editing chosen toolbox", %{conn: conn, toolbox: toolbox} do
      conn = get(conn, ~p"/tools/#{toolbox}/edit")
      assert html_response(conn, 200) =~ "Edit Toolbox"
    end
  end

  describe "update toolbox" do
    setup [:create_toolbox]

    test "redirects when data is valid", %{conn: conn, toolbox: toolbox} do
      conn = put(conn, ~p"/tools/#{toolbox}", toolbox: @update_attrs)
      assert redirected_to(conn) == ~p"/tools/#{toolbox}"

      conn = get(conn, ~p"/tools/#{toolbox}")
      assert html_response(conn, 200)
    end

    test "renders errors when data is invalid", %{conn: conn, toolbox: toolbox} do
      conn = put(conn, ~p"/tools/#{toolbox}", toolbox: @invalid_attrs)
      assert html_response(conn, 200) =~ "Edit Toolbox"
    end
  end

  describe "delete toolbox" do
    setup [:create_toolbox]

    test "deletes chosen toolbox", %{conn: conn, toolbox: toolbox} do
      conn = delete(conn, ~p"/tools/#{toolbox}")
      assert redirected_to(conn) == ~p"/tools"

      assert_error_sent 404, fn ->
        get(conn, ~p"/tools/#{toolbox}")
      end
    end
  end

  defp create_toolbox(_) do
    toolbox = toolbox_fixture()
    %{toolbox: toolbox}
  end
end
