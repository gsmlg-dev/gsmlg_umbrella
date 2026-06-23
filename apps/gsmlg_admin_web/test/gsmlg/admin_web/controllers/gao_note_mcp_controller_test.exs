defmodule GSMLG.AdminWeb.GaoNoteMCPControllerTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import GSMLG.AccountsFixtures

  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{Asset, Log, MCPSetting, Note, Reference, Tag, Tagging}
  alias GSMLG.Repo
  alias GSMLG.Storage.StorageFile

  setup do
    Repo.delete_all(MCPSetting)
    Repo.delete_all(Log)
    Repo.delete_all(Asset)
    Repo.delete_all(Reference)
    Repo.delete_all(Tagging)
    Repo.delete_all(Tag)
    Repo.delete_all(Note)
    Repo.delete_all(StorageFile)
    :ok
  end

  test "admin MCP requires authentication", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> post(~p"/mcp/gao_note", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{}
      })

    assert json_response(conn, 401)["message"] =~ "no_resource"
  end

  test "admin MCP initialize is handled by Anubis Streamable HTTP", %{conn: conn} do
    conn =
      conn
      |> authenticated_conn()
      |> put_req_header("accept", "application/json")
      |> post(~p"/mcp/gao_note", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "gao-note-admin-test", "version" => "0.1.0"}
        }
      })

    assert [_session_id] = get_resp_header(conn, "mcp-session-id")

    assert %{
             "result" => %{
               "serverInfo" => %{"name" => "gsmlg-gao-note-admin"},
               "capabilities" => %{"tools" => %{}, "resources" => %{}}
             }
           } = json_response(conn, 200)
  end

  test "admin MCP tools/list exposes CRUD tools with bearer token", %{conn: conn} do
    conn =
      conn
      |> authenticated_conn()
      |> put_req_header("accept", "application/json")
      |> post(~p"/mcp/gao_note", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{}
      })

    names = conn |> json_response(200) |> get_in(["result", "tools"]) |> Enum.map(& &1["name"])

    assert "gao_note.create" in names
    assert "gao_note.create_tag" in names
    assert "gao_note.delete" in names
    assert "gao_note.assets.upload_base64" in names
    refute "gao_note.publish" in names
    refute "gao_note.archive" in names
  end

  test "admin MCP tools/list accepts the GaoNote MCP API key", %{conn: conn} do
    user = user_fixture(%{email: "mcp-key@example.test", username: "mcp_key_user"})
    api_key = GaoNote.generate_mcp_api_key()
    assert {:ok, _setting} = GaoNote.set_mcp_api_key(api_key, user)

    conn =
      conn
      |> put_req_header("x-gaonote-mcp-key", api_key)
      |> put_req_header("accept", "application/json")
      |> post(~p"/mcp/gao_note", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{}
      })

    names = conn |> json_response(200) |> get_in(["result", "tools"]) |> Enum.map(& &1["name"])

    assert "gao_note.create" in names
    assert "gao_note.create_tag" in names
    assert "gao_note.delete" in names
  end

  test "admin MCP tools/call creates tags explicitly", %{conn: conn} do
    conn = call_mcp_tool(conn, "gao_note.create_tag", %{"name" => "agent-memory"})

    assert %{"result" => %{"structuredContent" => %{"tag" => tag}}} =
             json_response(conn, 200)

    assert tag["name"] == "agent-memory"
    refute Map.has_key?(tag, "slug")
  end

  test "admin MCP tools/call set_tags accepts existing and new tag names", %{conn: conn} do
    assert {:ok, note} =
             GaoNote.create_note(
               %{title: "Tag target", content: "Markdown content"},
               %{id: "seed-actor"}
             )

    assert {:ok, _tag} = GaoNote.create_tag(%{name: "github-trending"})

    conn =
      call_mcp_tool(conn, "gao_note.set_tags", %{
        "id" => note.id,
        "tags" => ["github-trending", "agent-memory"]
      })

    assert %{"result" => %{"structuredContent" => %{"note" => tagged}}} =
             json_response(conn, 200)

    assert Enum.map(tagged["tags"], & &1["name"]) == ["agent-memory", "github-trending"]
    assert Enum.map(GaoNote.list_tags(), & &1.name) == ["agent-memory", "github-trending"]
  end

  test "admin MCP tools/call update accepts tags only", %{conn: conn} do
    assert {:ok, note} =
             GaoNote.create_note(
               %{title: "Update tags target", content: "Markdown content"},
               %{id: "seed-actor"}
             )

    conn =
      call_mcp_tool(conn, "gao_note.update", %{
        "id" => note.id,
        "tags" => ["agent-memory"]
      })

    assert %{"result" => %{"structuredContent" => %{"note" => tagged}}} =
             json_response(conn, 200)

    assert tagged["title"] == "Update tags target"
    assert Enum.map(tagged["tags"], & &1["name"]) == ["agent-memory"]
  end

  defp authenticated_conn(conn) do
    user = user_fixture()

    {:ok, token, _claims} =
      GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp call_mcp_tool(conn, name, arguments) do
    conn
    |> authenticated_conn()
    |> put_req_header("accept", "application/json")
    |> post(~p"/mcp/gao_note", %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => arguments}
    })
  end
end
