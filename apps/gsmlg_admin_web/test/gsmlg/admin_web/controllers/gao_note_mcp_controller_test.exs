defmodule GSMLG.AdminWeb.GaoNoteMCPControllerTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import GSMLG.AccountsFixtures

  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{Asset, Label, LabelSetting, Log, MCPSetting, Note, Reference}
  alias GSMLG.Repo
  alias GSMLG.Storage.StorageFile

  setup do
    Repo.delete_all(MCPSetting)
    Repo.delete_all(Log)
    Repo.delete_all(Asset)
    Repo.delete_all(Reference)
    Repo.delete_all(Label)
    Repo.delete_all(LabelSetting)
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

  test "admin MCP initialize is handled by Backplane Streamable HTTP", %{conn: conn} do
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

    tools = conn |> json_response(200) |> get_in(["result", "tools"])
    names = Enum.map(tools, & &1["name"])

    assert "gao_note.create" in names
    assert "gao_note.create_label_setting" in names
    assert "gao_note.delete" in names
    assert "gao_note.assets.upload_base64" in names
    refute "gao_note.publish" in names
    refute "gao_note.archive" in names

    create = Enum.find(tools, &(&1["name"] == "gao_note.create"))

    assert create |> get_in(["inputSchema", "properties"]) |> Map.keys() |> Enum.sort() == [
             "content",
             "labels",
             "title"
           ]

    assert Enum.sort(get_in(create, ["inputSchema", "required"])) == ["content", "title"]
    refute "creator" in Map.keys(get_in(create, ["inputSchema", "properties"]))
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
    assert "gao_note.create_label_setting" in names
    assert "gao_note.delete" in names
  end

  test "admin MCP tools/call creates label settings explicitly", %{conn: conn} do
    conn = call_mcp_tool(conn, "gao_note.create_label_setting", %{"name" => "agent-memory"})

    assert %{"result" => %{"structuredContent" => %{"label_setting" => label_setting}}} =
             json_response(conn, 200)

    assert label_setting["name"] == "agent-memory"
    refute Map.has_key?(label_setting, "slug")
  end

  test "admin MCP tools/call set_labels accepts existing and new label keys", %{conn: conn} do
    assert {:ok, note} =
             GaoNote.create_note(
               %{title: "Label target", content: "Markdown content"},
               %{id: "seed-actor"}
             )

    assert {:ok, _label_setting} = GaoNote.create_label_setting(%{name: "github-trending"})

    conn =
      call_mcp_tool(conn, "gao_note.set_labels", %{
        "id" => note.id,
        "labels" => ["github-trending", "agent-memory"]
      })

    assert %{"result" => %{"structuredContent" => %{"note" => labeled}}} =
             json_response(conn, 200)

    assert Enum.map(labeled["labels"], &Map.take(&1, ["key", "value"])) == [
             %{"key" => "agent-memory", "value" => ""},
             %{"key" => "github-trending", "value" => ""}
           ]

    assert Enum.map(GaoNote.list_label_settings(), & &1.name) == [
             "agent-memory",
             "github-trending"
           ]
  end

  test "admin MCP tools/call update accepts labels only", %{conn: conn} do
    assert {:ok, note} =
             GaoNote.create_note(
               %{title: "Update labels target", content: "Markdown content"},
               %{id: "seed-actor"}
             )

    conn =
      call_mcp_tool(conn, "gao_note.update", %{
        "id" => note.id,
        "labels" => ["agent-memory"]
      })

    assert %{"result" => %{"structuredContent" => %{"note" => labeled}}} =
             json_response(conn, 200)

    assert labeled["title"] == "Update labels target"
    assert [%{"key" => "agent-memory", "value" => ""}] = labeled["labels"]
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
