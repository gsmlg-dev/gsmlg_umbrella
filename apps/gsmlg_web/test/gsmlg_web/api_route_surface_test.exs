defmodule GSMLG.Web.ApiRouteSurfaceTest do
  use GSMLG.Web.ConnCase

  @removed_routes [
    {:post, "/api/sign_in"},
    {:post, "/api/sign_up"},
    {:delete, "/api/sign_out"},
    {:get, "/api/blogs/:id"},
    {:post, "/api/blogs"},
    {:put, "/api/blogs/:id"},
    {:delete, "/api/blogs/:id"}
  ]

  test "does not register removed auth or blog API routes" do
    routes =
      GSMLG.Web.Router
      |> Phoenix.Router.routes()
      |> MapSet.new(&{&1.verb, &1.path})

    assert MapSet.disjoint?(routes, MapSet.new(@removed_routes))
  end

  test "forwards the canonical MCP route to the authenticated Agent Note plug" do
    routes =
      GSMLG.Web.Router
      |> Phoenix.Router.routes()
      |> Enum.filter(&String.starts_with?(&1.path, "/mcp"))

    assert [
             %{
               path: "/mcp",
               verb: :*,
               metadata: %{forward: ["mcp"]},
               plug: GSMLG.Web.AgentNoteMCPPlug
             }
           ] = routes
  end

  test "rejects unauthenticated requests to the canonical MCP endpoint", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"}))

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
    assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    assert conn.halted
  end

  test "removed API routes use the existing JSON 404 response" do
    for {method, path} <- [
          {:post, "/api/sign_in"},
          {:post, "/api/sign_up"},
          {:delete, "/api/sign_out"},
          {:get, "/api/blogs/missing"},
          {:post, "/api/blogs"},
          {:put, "/api/blogs/missing"},
          {:delete, "/api/blogs/missing"}
        ] do
      conn = dispatch(build_conn(), @endpoint, method, path, %{})

      assert %{"errors" => %{"detail" => "Not Found"}} = json_response(conn, 404)
    end
  end

  test "does not supervise the public read-only MCP server" do
    child_ids =
      GSMLG.Web.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(&elem(&1, 0))

    refute GSMLG.GaoNote.MCP.ReadOnlyServer in child_ids
  end
end
