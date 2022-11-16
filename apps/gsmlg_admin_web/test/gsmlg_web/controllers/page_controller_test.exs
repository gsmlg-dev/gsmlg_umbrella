defmodule GSMLGAdminWeb.PageControllerTest do
  use GSMLGAdminWeb.ConnCase

  # default action will rederect to sign_in
  test "GET /", %{conn: conn} do
    conn = get(conn, "/")
    assert html_response(conn, 302) =~ "sign_in"
  end
end
