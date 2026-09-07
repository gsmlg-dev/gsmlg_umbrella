defmodule GSMLG.AdminWeb.BrowserAPI.AuthAndRoutesTest do
  use GSMLG.AdminWeb.ConnCase, async: true

  @browser_routes MapSet.new([
                    {:get, "/api/browser/nodes"},
                    {:get, "/api/browser/nodes/:node_id"},
                    {:get, "/api/browser/nodes/:node_id/profiles"},
                    {:post, "/api/browser/nodes/:node_id/profiles/sync"},
                    {:patch, "/api/browser/profiles/:id"},
                    {:post, "/api/browser/profiles/:id/launch"},
                    {:post, "/api/browser/profiles/:id/stop"},
                    {:post, "/api/browser/sessions"},
                    {:get, "/api/browser/sessions/:id"},
                    {:post, "/api/browser/sessions/:id/observe"},
                    {:post, "/api/browser/sessions/:id/actions"},
                    {:post, "/api/browser/sessions/:id/manual-acquire"},
                    {:post, "/api/browser/sessions/:id/manual-release"},
                    {:delete, "/api/browser/sessions/:id"},
                    {:post, "/api/browser/jobs"},
                    {:get, "/api/browser/jobs"},
                    {:get, "/api/browser/jobs/:id"},
                    {:get, "/api/browser/jobs/:id/events"},
                    {:post, "/api/browser/jobs/:id/cancel"},
                    {:post, "/api/browser/jobs/:id/retry"},
                    {:post, "/api/browser/jobs/:id/resume"},
                    {:post, "/api/browser/jobs/:id/reconcile"},
                    {:get, "/api/browser/jobs/:id/artifacts"},
                    {:get, "/api/browser/artifacts/:id"},
                    {:get, "/api/browser/artifacts/:id/content"}
                  ])

  test "router exposes exactly the 25 Browser operations" do
    actual =
      GSMLG.AdminWeb.Router.__routes__()
      |> Enum.filter(&String.starts_with?(&1.path, "/api/browser"))
      |> Enum.reject(&(&1.path in ["/api/browser/openapi.json", "/api/browser/*request_path"]))
      |> Enum.map(&{&1.verb, &1.path})
      |> MapSet.new()

    assert actual == @browser_routes
  end

  test "Browser resources, spec, and Admin-origin catalog use the six-field auth error", %{
    conn: conn
  } do
    id = Ecto.UUID.generate()

    concrete_routes =
      Enum.map(@browser_routes, fn {method, path} ->
        path = path |> String.replace(":node_id", id) |> String.replace(":id", id)
        {method, path}
      end) ++ [{:get, "/api/browser/openapi.json"}, {:get, "/.well-known/api-catalog"}]

    for {method, path} <- concrete_routes do
      response_conn = dispatch_browser(conn |> recycle(), method, path)
      response = json_response(response_conn, 401)

      assert MapSet.new(Map.keys(response)) ==
               MapSet.new(~w(class code message retryable human_action details))

      assert response == %{
               "class" => "authentication",
               "code" => "authentication_required",
               "message" => "A valid Admin bearer access token is required.",
               "retryable" => false,
               "human_action" => "authenticate",
               "details" => %{}
             }

      assert ["no-store"] = get_resp_header(response_conn, "cache-control")
      assert ["nosniff"] = get_resp_header(response_conn, "x-content-type-options")
    end
  end

  test "existing Admin bearer endpoints retain their legacy auth response", %{conn: conn} do
    response = conn |> post("/api/scout/fetch", %{}) |> json_response(401)

    assert %{"message" => message} = response
    assert message =~ "ApiAuthErrorHandler"
    refute Map.has_key?(response, "class")
  end

  test "unknown Browser paths keep the Browser error contract", %{conn: conn} do
    conn = authenticated_conn(conn)

    assert %{
             "class" => "request",
             "code" => "not_found",
             "retryable" => false,
             "human_action" => nil,
             "details" => %{}
           } = json_response(get(conn, "/api/browser/not-a-route"), 404)
  end

  test "all bearer authentication failures have an indistinguishable public response", %{
    conn: conn
  } do
    missing = conn |> get("/api/browser/nodes") |> json_response(401)

    user = GSMLG.AccountsFixtures.user_fixture()

    {:ok, refresh_token, _claims} =
      GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "refresh")

    {:ok, expired_token, _claims} =
      GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{},
        token_type: "access",
        ttl: {-1, :second}
      )

    {:ok, revoked_token, _claims} =
      GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

    assert {:ok, _claims} = GSMLG.AdminWeb.Guardian.revoke(revoked_token)

    for authorization <- [
          "Bearer malformed",
          "Basic not-a-bearer",
          "Bearer ",
          "Bearer #{refresh_token}",
          "Bearer #{expired_token}",
          "Bearer #{revoked_token}"
        ] do
      response =
        conn
        |> recycle()
        |> put_req_header("authorization", authorization)
        |> get("/api/browser/nodes")
        |> json_response(401)

      assert response == missing
    end

    assert ["no-store"] =
             get_resp_header(conn |> recycle() |> get("/api/browser/nodes"), "cache-control")

    assert ["nosniff"] =
             get_resp_header(
               conn |> recycle() |> get("/api/browser/nodes"),
               "x-content-type-options"
             )
  end

  defp authenticated_conn(conn) do
    user = GSMLG.AccountsFixtures.user_fixture()

    {:ok, token, _claims} =
      GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp dispatch_browser(conn, :get, path), do: get(conn, path)
  defp dispatch_browser(conn, :post, path), do: post(conn, path, %{})
  defp dispatch_browser(conn, :patch, path), do: patch(conn, path, %{})
  defp dispatch_browser(conn, :delete, path), do: delete(conn, path, %{})
end
