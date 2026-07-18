defmodule GSMLG.AdminWeb.GaoNoteMCPControllerTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import GSMLG.AccountsFixtures

  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{Attachment, Label, LabelSetting, Log, MCPSetting, Note}
  alias GSMLG.Repo
  alias GSMLG.Storage.StorageFile

  @removed_tool_names ~w(
    gao_note.create
    gao_note.update
    gao_note.list_attachments
    gao_note.attachments.attach_existing
    gao_note.attachments.upload_base64
    gao_note.attachments.update
    gao_note.attachments.detach
    gao_note.list_references
    gao_note.references.add
    gao_note.list_assets
    gao_note.assets.upload_base64
  )

  setup do
    Repo.delete_all(MCPSetting)
    Repo.delete_all(Log)
    Repo.delete_all(Attachment)
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

    assert Enum.sort(names) == ~w(
             gao_note.create_label_setting
             gao_note.create_note
             gao_note.delete
             gao_note.get
             gao_note.list_label_settings
             gao_note.search
             gao_note.set_labels
             gao_note.update_note
           )

    assert Enum.filter(@removed_tool_names, &(&1 in names)) == []

    create = Enum.find(tools, &(&1["name"] == "gao_note.create_note"))

    assert create |> get_in(["inputSchema", "properties"]) |> Map.keys() |> Enum.sort() == [
             "attachments",
             "content",
             "labels",
             "title"
           ]

    assert Enum.sort(get_in(create, ["inputSchema", "required"])) == ["content", "title"]
    assert get_in(create, ["inputSchema", "properties", "attachments", "default"]) == []
    refute "creator" in Map.keys(get_in(create, ["inputSchema", "properties"]))

    update = Enum.find(tools, &(&1["name"] == "gao_note.update_note"))
    assert Enum.sort(get_in(update, ["inputSchema", "required"])) == ["attachments", "id"]
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

    assert "gao_note.create_note" in names
    assert "gao_note.create_label_setting" in names
    assert "gao_note.update_note" in names
    assert "gao_note.delete" in names
    assert Enum.filter(@removed_tool_names, &(&1 in names)) == []
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

  test "admin MCP update_note rejects a missing aggregate attachment list", %{conn: conn} do
    assert {:ok, note} =
             GaoNote.create_note(
               %{title: "Missing attachments target", content: "Markdown content"},
               %{id: "seed-actor"}
             )

    conn =
      call_mcp_tool(conn, "gao_note.update_note", %{
        "id" => note.id,
        "title" => "Must not update"
      })

    message = assert_invalid_params(json_response(conn, 200))

    assert message =~ "attachments"
    assert message =~ "required"
    assert GaoNote.get_note(note.id).title == "Missing attachments target"
  end

  test "admin MCP aggregate update removes attachments omitted from the complete list", %{
    conn: conn
  } do
    first_id = unique_id("first-attachment")
    second_id = unique_id("second-attachment")

    create_conn =
      call_mcp_tool(conn, "gao_note.create_note", %{
        "title" => unique_id("Aggregate replacement"),
        "content" => "See [first](./files/first.txt) and [second](./files/second.txt)",
        "attachments" => [
          %{
            "id" => first_id,
            "path" => "files/first.txt",
            "mime" => "text/plain",
            "description" => "First",
            "content" => "first attachment"
          },
          %{
            "id" => second_id,
            "path" => "files/second.txt",
            "mime" => "text/plain",
            "description" => "Second",
            "content" => "second attachment"
          }
        ]
      })

    assert %{"result" => %{"structuredContent" => %{"note" => created}}} =
             json_response(create_conn, 200)

    assert [
             %{"id" => ^first_id, "path" => "./files/first.txt"} = first,
             %{"id" => ^second_id, "path" => "./files/second.txt"}
           ] = created["attachments"]

    retained = Map.take(first, ~w(id path mime description))

    update_conn =
      call_mcp_tool(conn, "gao_note.update_note", %{
        "id" => created["id"],
        "attachments" => [retained]
      })

    assert %{"result" => %{"structuredContent" => %{"note" => updated}}} =
             json_response(update_conn, 200)

    assert [%{"id" => ^first_id, "path" => "./files/first.txt"}] =
             updated["attachments"]

    assert [^first_id] =
             created["id"]
             |> GaoNote.get_note()
             |> Map.fetch!(:attachments)
             |> Enum.map(& &1.id)
  end

  test "admin MCP rejects nil-valued unknown nested attachment fields before dispatch", %{
    conn: conn
  } do
    title = unique_id("Strict aggregate")

    conn =
      call_mcp_tool(conn, "gao_note.create_note", %{
        "title" => title,
        "content" => "body",
        "attachments" => [
          %{
            "id" => unique_id("strict-attachment"),
            "path" => "data.txt",
            "mime" => "text/plain",
            "content" => "data",
            "role" => nil
          }
        ]
      })

    message = assert_invalid_params(json_response(conn, 200))

    assert message =~ "is required"
    refute Repo.get_by(Note, title: title)
  end

  test "admin MCP rejects nil-valued unknown top-level note fields before dispatch", %{conn: conn} do
    title = unique_id("Strict note")

    conn =
      call_mcp_tool(conn, "gao_note.create_note", %{
        "title" => title,
        "content" => "body",
        "creator" => nil
      })

    message = assert_invalid_params(json_response(conn, 200))

    assert message =~ "is required"
    refute Repo.get_by(Note, title: title)
  end

  test "admin MCP rejects invalid attachment Base64 before dispatch", %{conn: conn} do
    title = unique_id("Invalid Base64")

    conn =
      call_mcp_tool(conn, "gao_note.create_note", %{
        "title" => title,
        "content" => "body",
        "attachments" => [
          %{
            "id" => unique_id("invalid-base64"),
            "path" => "data.txt",
            "mime" => "text/plain",
            "content_base64" => "Zg"
          }
        ]
      })

    message = assert_invalid_params(json_response(conn, 200))
    assert message =~ "strict standard padded Base64"
    refute Repo.get_by(Note, title: title)
  end

  test "admin MCP rejects attachment content and content_base64 before dispatch", %{conn: conn} do
    title = unique_id("Conflicting content")

    conn =
      call_mcp_tool(conn, "gao_note.create_note", %{
        "title" => title,
        "content" => "body",
        "attachments" => [
          %{
            "id" => unique_id("conflicting-content"),
            "path" => "data.txt",
            "mime" => "text/plain",
            "content" => "data",
            "content_base64" => "ZGF0YQ=="
          }
        ]
      })

    message = assert_invalid_params(json_response(conn, 200))
    assert message =~ "only one of content or content_base64"
    refute Repo.get_by(Note, title: title)
  end

  test "admin MCP rejects explicit nil attachment content before dispatch", %{conn: conn} do
    title = unique_id("Nil content")

    conn =
      call_mcp_tool(conn, "gao_note.create_note", %{
        "title" => title,
        "content" => "body",
        "attachments" => [
          %{
            "id" => unique_id("nil-content"),
            "path" => "data.txt",
            "mime" => "text/plain",
            "content" => nil
          }
        ]
      })

    message = assert_invalid_params(json_response(conn, 200))
    assert message =~ "content must be a string"
    refute Repo.get_by(Note, title: title)
  end

  test "admin MCP rejects explicit nil attachment content_base64 before dispatch", %{conn: conn} do
    title = unique_id("Nil Base64")

    conn =
      call_mcp_tool(conn, "gao_note.create_note", %{
        "title" => title,
        "content" => "body",
        "attachments" => [
          %{
            "id" => unique_id("nil-base64"),
            "path" => "data.txt",
            "mime" => "text/plain",
            "content_base64" => nil
          }
        ]
      })

    message = assert_invalid_params(json_response(conn, 200))
    assert message =~ "content_base64 must be a string"
    refute Repo.get_by(Note, title: title)
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

  defp assert_invalid_params(response) do
    assert %{
             "error" => %{
               "code" => -32_602,
               "message" => "Invalid params",
               "data" => %{"message" => message}
             }
           } = response

    message
  end

  defp unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
