defmodule GSMLG.Web.ToolboxControllerTest do
  use GSMLG.Web.ConnCase

  describe "index" do
    test "lists all tools", %{conn: conn} do
      conn = get(conn, ~p"/toolbox")
      assert html_response(conn, 200) =~ "Toolbox"
    end
  end

  describe "ip_geo" do
    test "renders form", %{conn: conn} do
      conn = get(conn, ~p"/toolbox/ip_geo")
      assert html_response(conn, 200) =~ "IP Geo"
    end
  end

  describe "search ip_geo" do
    test "redirects to show when data is valid", %{conn: conn} do
      conn = post(conn, ~p"/toolbox/ip_geo", ip: "2.4.6.8")

      assert html_response(conn, 200) =~ "IP Geo"
      assert html_response(conn, 200) =~ "France"
    end

    test "renders errors when data is invalid", %{conn: conn} do
      conn = post(conn, ~p"/toolbox/ip_geo", ip: "not an ip")
      assert html_response(conn, 200) =~ "IP Geo"
    end
  end
end
