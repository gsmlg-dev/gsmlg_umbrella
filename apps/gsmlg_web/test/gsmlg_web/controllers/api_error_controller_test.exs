defmodule GSMLG.Web.ApiErrorControllerTest do
  use GSMLG.Web.ConnCase

  test "unknown API GET returns JSON 404 without an accept header", %{conn: conn} do
    conn = get(conn, ~p"/api/does-not-exist")

    assert %{"errors" => %{"detail" => "Not Found"}} = json_response(conn, 404)
  end

  test "API scope root returns JSON 404", %{conn: conn} do
    conn = get(conn, ~p"/api")

    assert %{"errors" => %{"detail" => "Not Found"}} = json_response(conn, 404)
  end

  test "unknown API POST returns JSON 404", %{conn: conn} do
    conn = post(conn, ~p"/api/does-not-exist", %{})

    assert %{"errors" => %{"detail" => "Not Found"}} = json_response(conn, 404)
  end

  test "API 404 ignores browser accept negotiation", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "text/html")
      |> get(~p"/api/does-not-exist")

    assert %{"errors" => %{"detail" => "Not Found"}} = json_response(conn, 404)
  end

  test "controller-level API errors render JSON", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "text/html")
      |> get(~p"/api/gao_notes/#{Ecto.UUID.generate()}")

    assert %{"errors" => %{"detail" => "Not Found"}} = json_response(conn, 404)
  end
end
