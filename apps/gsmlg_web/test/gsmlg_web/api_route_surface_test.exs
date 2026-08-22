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

  test "does not expose MCP routes from the public router" do
    refute GSMLG.Web.Router
           |> Phoenix.Router.routes()
           |> Enum.any?(&String.starts_with?(&1.path, "/mcp"))
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
