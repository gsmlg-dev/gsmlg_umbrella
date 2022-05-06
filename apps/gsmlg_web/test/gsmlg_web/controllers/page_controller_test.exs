defmodule GSMLGWeb.PageControllerTest do
  use GSMLGWeb.ConnCase

  test "GET /not_found", %{conn: conn} do
    conn = get(conn, "/not_found")
    assert html_response(conn, 404) =~ "BITW"
  end
end
