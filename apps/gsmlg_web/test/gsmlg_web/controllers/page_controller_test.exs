defmodule GSMLGWeb.PageControllerTest do
  use GSMLGWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, "/")
    assert html_response(conn, 200) =~ "Home"
  end

  test "GET /not_found", %{conn: conn} do
    conn = get(conn, "/not_found")
    assert html_response(conn, 404) =~ "404"
  end
end
