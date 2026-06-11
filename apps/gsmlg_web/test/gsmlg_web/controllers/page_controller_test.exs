defmodule GSMLG.Web.PageControllerTest do
  use GSMLG.Web.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, "/")
    assert html_response(conn, 200) =~ "Home"
  end

  test "GET / includes a DuskMoon theme on the html root", %{conn: conn} do
    conn = get(conn, "/")
    assert html_response(conn, 200) =~ ~s(<html lang="en" data-theme="sunshine">)
  end

  test "GET /not_found", %{conn: conn} do
    conn = get(conn, "/not_found")
    assert html_response(conn, 404) =~ "404"
  end
end
