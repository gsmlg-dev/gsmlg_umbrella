defmodule GSMLGWeb.BlogControllerTest do
  use GSMLGWeb.ConnCase

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "index" do
    test "lists all blogs", %{conn: conn} do
      conn = get(conn, ~p"/api/blogs")
      assert json_response(conn, 200)["data"] == []
    end
  end
end
