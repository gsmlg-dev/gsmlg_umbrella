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
             gao_note.delete_attachment
             gao_note.get
             gao_note.get_attachment_with_content
             gao_note.list_label_settings
             gao_note.put_attachment
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
    assert get_in(create, ["inputSchema", "additionalProperties"]) == false
    refute "creator" in Map.keys(get_in(create, ["inputSchema", "properties"]))

    update = Enum.find(tools, &(&1["name"] == "gao_note.update_note"))

    assert update |> get_in(["inputSchema", "properties"]) |> Map.keys() |> Enum.sort() ==
             ~w(content id labels title)

    assert get_in(update, ["inputSchema", "required"]) == ["id"]
    assert get_in(update, ["inputSchema", "additionalProperties"]) == false
    refute Map.has_key?(get_in(update, ["inputSchema", "properties"]), "attachments")

    assert_standalone_attachment_contracts(tools)
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
    assert "gao_note.get_attachment_with_content" in names
    assert "gao_note.put_attachment" in names
    assert "gao_note.delete_attachment" in names
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

  test "admin MCP update_note preserves attachments and rejects them as additional params", %{
    conn: conn
  } do
    assert {:ok, note} =
             GaoNote.create_note(
               %{title: "Standalone update target", content: "Markdown content"},
               %{id: "seed-actor"}
             )

    attachment =
      attachment_fixture(
        note,
        unique_id("preserved-attachment"),
        "preserved.txt",
        "Preserved"
      )

    update_conn =
      call_mcp_tool(conn, "gao_note.update_note", %{
        "id" => note.id,
        "title" => "Field-only update",
        "content" => "Updated markdown",
        "labels" => ["scope=standalone"]
      })

    assert %{"result" => %{"structuredContent" => %{"note" => updated}}} =
             json_response(update_conn, 200)

    assert updated["title"] == "Field-only update"
    assert updated["content"] == "Updated markdown"
    assert [%{"id" => attachment_id} = presented_attachment] = updated["attachments"]
    assert attachment_id == attachment.id
    assert_attachment_metadata_only(presented_attachment)

    assert %Attachment{storage_file_id: storage_file_id} =
             Repo.get!(Attachment, attachment.id)

    assert storage_file_id == attachment.storage_file_id

    rejected_conn =
      call_mcp_tool(conn, "gao_note.update_note", %{
        "id" => note.id,
        "title" => "Must not update",
        "attachments" => []
      })

    message = assert_invalid_params(json_response(rejected_conn, 200))
    assert message =~ "attachments"
    assert GaoNote.get_note(note.id).title == "Field-only update"
    assert %Attachment{storage_file_id: ^storage_file_id} = Repo.get!(Attachment, attachment.id)
  end

  test "admin MCP standalone put and delete mutate only the selected attachment", %{
    conn: conn
  } do
    user = user_fixture()
    authenticated = authenticated_conn(conn, user)

    assert {:ok, note} =
             GaoNote.create_note(
               %{title: "Standalone attachment calls", content: "Markdown content"},
               %{id: "seed-actor"}
             )

    selected =
      attachment_fixture(note, unique_id("selected"), "selected.txt", "Selected")

    retained =
      attachment_fixture(note, unique_id("retained"), "retained.txt", "Retained")

    put_conn =
      call_authenticated_mcp_tool(authenticated, "gao_note.put_attachment", %{
        "note_id" => note.id,
        "attachment_id" => selected.id,
        "path" => "renamed.txt",
        "mime" => "text/plain",
        "description" => "Renamed",
        "update_content" => false
      })

    assert %{"result" => %{"structuredContent" => %{"attachment" => updated}}} =
             json_response(put_conn, 200)

    assert updated["id"] == selected.id
    assert updated["path"] == "./renamed.txt"
    assert updated["description"] == "Renamed"
    assert_attachment_metadata_only(updated)

    assert %Attachment{storage_file_id: storage_file_id} =
             Repo.get!(Attachment, selected.id)

    assert storage_file_id == selected.storage_file_id

    delete_conn =
      call_authenticated_mcp_tool(authenticated, "gao_note.delete_attachment", %{
        "note_id" => note.id,
        "attachment_id" => selected.id
      })

    assert %{"result" => %{"structuredContent" => %{"attachment" => deleted}}} =
             json_response(delete_conn, 200)

    assert deleted["id"] == selected.id
    assert_attachment_metadata_only(deleted)
    assert Repo.get(Attachment, selected.id) == nil
    assert %Attachment{id: retained_id} = Repo.get(Attachment, retained.id)
    assert retained_id == retained.id

    assert %Log{source: "mcp", actor_id: actor_id} =
             Repo.get_by!(Log,
               entity_type: "attachment",
               entity_id: selected.id,
               action: "update"
             )

    assert actor_id == user.id

    assert %Log{source: "mcp", actor_id: actor_id} =
             Repo.get_by!(Log,
               entity_type: "attachment",
               entity_id: selected.id,
               action: "delete"
             )

    assert actor_id == user.id
  end

  test "admin MCP identifies non-nil unknown nested attachment fields before dispatch", %{
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
            "role" => "source"
          }
        ]
      })

    message = assert_invalid_params(json_response(conn, 200))

    assert message =~ "role"
    assert message =~ "unsupported attachment field"
    refute Repo.get_by(Note, title: title)
  end

  test "admin MCP identifies non-nil unknown top-level note fields before dispatch", %{conn: conn} do
    title = unique_id("Strict note")

    conn =
      call_mcp_tool(conn, "gao_note.create_note", %{
        "title" => title,
        "content" => "body",
        "creator" => "legacy-creator"
      })

    message = assert_invalid_params(json_response(conn, 200))

    assert message =~ "creator"
    assert message =~ "unsupported note field"
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

  defp authenticated_conn(conn), do: authenticated_conn(conn, user_fixture())

  defp authenticated_conn(conn, user) do
    {:ok, token, _claims} =
      GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp call_mcp_tool(conn, name, arguments) do
    conn
    |> authenticated_conn()
    |> call_authenticated_mcp_tool(name, arguments)
  end

  defp call_authenticated_mcp_tool(conn, name, arguments) do
    conn
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

  defp assert_standalone_attachment_contracts(tools) do
    readonly_annotations = %{
      "readOnlyHint" => true,
      "destructiveHint" => false,
      "idempotentHint" => true,
      "openWorldHint" => false
    }

    write_annotations = %{
      "readOnlyHint" => false,
      "destructiveHint" => true,
      "idempotentHint" => true,
      "openWorldHint" => false
    }

    get_attachment = Enum.find(tools, &(&1["name"] == "gao_note.get_attachment_with_content"))

    assert get_attachment["inputSchema"] == %{
             "type" => "object",
             "additionalProperties" => false,
             "properties" => %{
               "note_id" => %{"type" => "string", "description" => "GaoNote id."},
               "attachment_id" => %{
                 "type" => "string",
                 "description" => "Globally unique attachment ID."
               }
             },
             "required" => ["note_id", "attachment_id"]
           }

    assert get_attachment["annotations"] == readonly_annotations

    put_attachment = Enum.find(tools, &(&1["name"] == "gao_note.put_attachment"))

    assert put_attachment["inputSchema"] == %{
             "type" => "object",
             "additionalProperties" => false,
             "properties" => %{
               "note_id" => %{"type" => "string", "description" => "GaoNote id."},
               "attachment_id" => %{
                 "type" => "string",
                 "description" => "Globally unique attachment ID."
               },
               "path" => %{
                 "type" => "string",
                 "description" => "Canonical note-relative path."
               },
               "mime" => %{
                 "type" => "string",
                 "description" => "Expected MIME type."
               },
               "description" => %{
                 "type" => "string",
                 "description" => "Attachment description."
               },
               "update_content" => %{
                 "type" => "boolean",
                 "description" =>
                   "Whether to replace stored content. False forbids content fields; true requires exactly one."
               },
               "content" => %{
                 "type" => "string",
                 "description" =>
                   "Raw replacement content. Use only when update_content is true."
               },
               "content_base64" => %{
                 "type" => "string",
                 "contentEncoding" => "base64",
                 "pattern" =>
                   "^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$",
                 "description" =>
                   "Strict standard padded Base64 replacement content. Use only when update_content is true."
               }
             },
             "required" => [
               "note_id",
               "attachment_id",
               "path",
               "mime",
               "description",
               "update_content"
             ]
           }

    assert put_attachment["annotations"] == write_annotations

    delete_attachment = Enum.find(tools, &(&1["name"] == "gao_note.delete_attachment"))

    assert delete_attachment["inputSchema"] == %{
             "type" => "object",
             "additionalProperties" => false,
             "properties" => %{
               "note_id" => %{"type" => "string", "description" => "GaoNote id."},
               "attachment_id" => %{
                 "type" => "string",
                 "description" => "Globally unique attachment ID."
               }
             },
             "required" => ["note_id", "attachment_id"]
           }

    assert delete_attachment["annotations"] == write_annotations
  end

  defp assert_attachment_metadata_only(attachment) do
    assert attachment |> Map.keys() |> Enum.sort() ==
             ~w(content_url description id mime path)
  end

  defp attachment_fixture(note, id, path, description) do
    file =
      %StorageFile{}
      |> StorageFile.changeset(%{
        tenant: note.id,
        type: "gao_note_attachment",
        filename: Path.basename(path),
        s3_key: "gao_note/#{Ecto.UUID.generate()}",
        content_type: "text/plain",
        size: 7,
        checksum: Ecto.UUID.generate(),
        metadata: %{},
        variants: %{},
        status: "active",
        uploaded_by: "fixture"
      })
      |> Repo.insert!()

    attachment =
      %Attachment{}
      |> Attachment.changeset(%{
        id: id,
        note_id: note.id,
        storage_file_id: file.id,
        path: path,
        mime: "text/plain",
        description: description
      })
      |> Repo.insert!()

    Repo.preload(attachment, :storage_file)
  end

  defp unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
