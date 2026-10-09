defmodule GSMLG.Web.AgentNoteMCPControllerTest do
  use GSMLG.Web.ConnCase, async: false
  import GSMLG.AccountsFixtures
  alias GSMLG.GaoNote

  @mcp_headers ~w(accept authorization x-gaonote-mcp-key mcp-session-id mcp-protocol-version)

  defp authenticated_conn do
    user =
      user_fixture(%{
        email: "gaonote-#{System.unique_integer([:positive])}@test",
        username: "gaonote_#{System.unique_integer([:positive])}"
      })

    {:ok, token, _claims} = GSMLG.Web.Guardian.encode_and_sign(user, %{}, token_type: "access")

    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("accept", "application/json, text/event-stream")
  end

  defp rpc(conn, method, params) do
    conn
    |> recycle(@mcp_headers)
    |> put_req_header("accept", "application/json, text/event-stream")
    |> post("/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})
  end

  defp initialized_conn(conn) do
    conn
    |> rpc("initialize", %{
      "protocolVersion" => "2025-06-18",
      "capabilities" => %{},
      "clientInfo" => %{"name" => "parity-test", "version" => "1"}
    })
    |> complete_initialization()
  end

  defp complete_initialization(conn) do
    assert json_response(conn, 200)["result"]["protocolVersion"] == "2025-06-18"
    assert [session_id] = get_resp_header(conn, "mcp-session-id")

    conn =
      conn
      |> recycle(@mcp_headers)
      |> put_req_header("mcp-session-id", session_id)
      |> put_req_header("mcp-protocol-version", "2025-06-18")
      |> post("/mcp", %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

    assert response(conn, 202)
    recycle(conn, @mcp_headers)
  end

  test "public canonical MCP requires authentication", %{conn: conn} do
    conn = rpc(conn, "tools/list", %{})
    assert %{"error" => "unauthorized"} = json_response(conn, 401)
  end

  test "public Guardian serves only canonical tools and legacy initialization" do
    conn =
      rpc(authenticated_conn(), "initialize", %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "parity-test", "version" => "1"}
      })

    assert [_session] = get_resp_header(conn, "mcp-session-id")

    assert %{
             "result" => %{
               "serverInfo" => %{"name" => "agent-note"},
               "capabilities" => capabilities
             }
           } = json_response(conn, 200)

    assert capabilities["tools"] == %{}
    refute Map.has_key?(capabilities, "resources")

    conn = conn |> complete_initialization() |> rpc("tools/list", %{})
    tools = json_response(conn, 200)["result"]["tools"]

    assert Enum.sort(Enum.map(tools, & &1["name"])) ==
             Enum.sort(GSMLG.GaoNote.MCP.AgentNoteTools.tool_names())
  end

  test "tools/call saves and hydrates canonical structured DTOs" do
    authenticated = authenticated_conn() |> initialized_conn()

    conn =
      rpc(authenticated, "tools/call", %{
        "name" => "save_note",
        "arguments" => %{
          "title" => "Public MCP",
          "content" => "Body",
          "labels" => [["key", "value"]]
        }
      })

    assert %{
             "result" => %{
               "isError" => false,
               "structuredContent" => %{"id" => id, "revision" => 1}
             }
           } = json_response(conn, 200)

    conn =
      rpc(authenticated, "tools/call", %{
        "name" => "get_note",
        "arguments" => %{"id" => id}
      })

    assert %{
             "result" => %{
               "structuredContent" => %{
                 "id" => ^id,
                 "content" => "Body",
                 "labels" => [%{"key" => "key", "value" => "value", "value_type" => "text"}]
               }
             }
           } = json_response(conn, 200)
  end

  test "service key authenticates but invalid and refresh credentials fail" do
    user =
      user_fixture(%{
        email: "gaonote-#{System.unique_integer([:positive])}@test",
        username: "gaonote_#{System.unique_integer([:positive])}"
      })

    key = GaoNote.generate_mcp_api_key()
    assert {:ok, _} = GaoNote.set_mcp_api_key(key, user)

    conn =
      build_conn()
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("x-gaonote-mcp-key", key)
      |> initialized_conn()
      |> rpc("tools/list", %{})

    assert %{"result" => %{"tools" => [_ | _]}} = json_response(conn, 200)
    conn = build_conn() |> put_req_header("x-api-key", "invalid") |> rpc("tools/list", %{})
    assert json_response(conn, 401) == %{"error" => "unauthorized"}
    {:ok, refresh, _} = GSMLG.Web.Guardian.encode_and_sign(user, %{}, token_type: "refresh")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{refresh}")
      |> rpc("tools/list", %{})

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end
end
