defmodule GSMLGWeb.ToolboxControllerTest do
  use GSMLGWeb.ConnCase

  describe "index" do
    test "lists all tools", %{conn: conn} do
      conn = get(conn, ~p"/tools")
      assert html_response(conn, 200) =~ "Toolbox"
    end
  end

  describe "geoip2" do
    test "renders form", %{conn: conn} do
      conn = get(conn, ~p"/tools/geoip2")
      assert html_response(conn, 200) =~ "GeoIP2"
    end
  end

  describe "search geoip2" do
    test "redirects to show when data is valid", %{conn: conn} do
      conn = post(conn, ~p"/tools/geoip2", ip: "2.4.6.8", lang: "en")

      assert html_response(conn, 200) =~ "GeoIP2"
      assert html_response(conn, 200) =~ "France"
    end

    test "renders errors when data is invalid", %{conn: conn} do
      conn = post(conn, ~p"/tools/geoip2", ip: "not an ip")
      assert html_response(conn, 200) =~ "GeoIP2"
    end
  end
end
