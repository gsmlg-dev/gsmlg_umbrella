defmodule GSMLG.GaoNote.MCPTest do
  use GSMLG.GaoNote.DataCase, async: false

  defmodule S3Stub do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    put "/*path" do
      {:ok, body, conn} = read_complete_body(conn, "")
      notify({:s3_put, conn.request_path, body})
      send_resp(conn, 200, "")
    end

    get "/*path" do
      ranges = Plug.Conn.get_req_header(conn, "range")
      object = Application.get_env(:gsmlg_storage, :gao_note_mcp_test_object, "")
      notify({:s3_get, conn.request_path, ranges})

      case ranges do
        ["bytes=" <> range] ->
          [first, last] =
            range
            |> String.split("-", parts: 2)
            |> Enum.map(&String.to_integer/1)

          send_resp(conn, 206, binary_part(object, first, last - first + 1))

        _ranges ->
          send_resp(conn, 200, object)
      end
    end

    delete "/*path" do
      notify({:s3_delete, conn.request_path})
      send_resp(conn, 204, "")
    end

    match _, do: send_resp(conn, 200, "")

    defp read_complete_body(conn, acc) do
      case Plug.Conn.read_body(conn) do
        {:ok, body, conn} -> {:ok, acc <> body, conn}
        {:more, body, conn} -> read_complete_body(conn, acc <> body)
      end
    end

    defp notify(message) do
      if pid = Application.get_env(:gsmlg_storage, :gao_note_mcp_test_pid) do
        send(pid, message)
      end
    end
  end

  alias Backplane.McpProtocol.Server.{Frame, Response}
  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{Attachment, Label, LabelSetting, Log, MCPSetting, Note}
  alias GSMLG.Accounts.User
  alias GSMLG.Storage.StorageFile

  @attachment_metadata_keys ~w(content_url description id mime path)
  @storage_keys [
    :allowed_types,
    :gao_note_mcp_test_object,
    :gao_note_mcp_test_pid,
    :s3_access_key_id,
    :s3_bucket,
    :s3_endpoint,
    :s3_secret_access_key
  ]

  setup do
    Repo.delete_all(MCPSetting)
    Repo.delete_all(Log)
    Repo.delete_all(Attachment)
    Repo.delete_all(Label)
    Repo.delete_all(LabelSetting)
    Repo.delete_all(Note)
    Repo.delete_all(StorageFile)

    original = Map.new(@storage_keys, &{&1, Application.fetch_env(:gsmlg_storage, &1)})
    {:ok, s3_stub} = Bandit.start_link(plug: S3Stub, port: 0, startup_log: false)
    {:ok, {_address, port}} = ThousandIsland.listener_info(s3_stub)

    Application.put_env(:gsmlg_storage, :allowed_types, %{"gao_note_attachment" => :any})
    Application.put_env(:gsmlg_storage, :gao_note_mcp_test_object, "")
    Application.put_env(:gsmlg_storage, :gao_note_mcp_test_pid, self())
    Application.put_env(:gsmlg_storage, :s3_access_key_id, "test-access-key")
    Application.put_env(:gsmlg_storage, :s3_bucket, "gsmlg-storage")
    Application.put_env(:gsmlg_storage, :s3_endpoint, "http://127.0.0.1:#{port}")
    Application.put_env(:gsmlg_storage, :s3_secret_access_key, "test-secret-key")

    on_exit(fn ->
      Enum.each(original, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)

      if Process.alive?(s3_stub), do: GenServer.stop(s3_stub)
    end)

    :ok
  end

  describe "readonly mode" do
    test "read-only Backplane server registers the exact standalone read tools" do
      names = GSMLG.GaoNote.MCP.ReadOnlyServer |> tool_names() |> Enum.sort()

      assert names == ~w(
               gao_note.get
               gao_note.get_attachment_with_content
               gao_note.list_label_settings
               gao_note.search
             )

      refute "gao_note.list_attachments" in names
      refute "gao_note.put_attachment" in names
      refute "gao_note.delete_attachment" in names
      refute Enum.any?(names, &String.starts_with?(&1, "gao_note.attachments."))
    end

    test "search and get return attachment metadata without bytes or storage fields" do
      frame = admin_frame(actor())
      attachment_id = unique_title("metadata-attachment")

      assert %{"structuredContent" => %{"note" => created_note}} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.create_note",
                 %{
                   "title" => "MCP Public Metadata",
                   "content" => "See [metadata](./docs/metadata.txt)",
                   "attachments" => [
                     %{
                       "id" => attachment_id,
                       "path" => "docs/metadata.txt",
                       "mime" => "text/plain",
                       "description" => "Metadata only",
                       "content" => "private attachment bytes"
                     }
                   ]
                 },
                 frame
               )

      assert %{"structuredContent" => %{"notes" => [searched]}} =
               call_tool(GSMLG.GaoNote.MCP.ReadOnlyServer, "gao_note.search", %{"query" => "MCP"})

      assert searched["id"] == created_note["id"]
      assert searched["title"] == "MCP Public Metadata"
      assert_note_attachment_metadata(searched, attachment_id)

      assert %{"structuredContent" => %{"note" => fetched}} =
               call_tool(GSMLG.GaoNote.MCP.ReadOnlyServer, "gao_note.get", %{
                 "id" => created_note["id"]
               })

      assert fetched["id"] == created_note["id"]
      assert_note_attachment_metadata(fetched, attachment_id)

      assert %{"isError" => true} =
               call_tool(GSMLG.GaoNote.MCP.ReadOnlyServer, "gao_note.get", %{
                 "id" => created_note["id"] <> "-missing"
               })
    end

    test "get_attachment_with_content returns exact Base64 bytes in readonly and admin modes" do
      bytes = <<0, 1, 2, 3, 255>>
      note = note_fixture(%{title: "Binary attachment"})

      attachment =
        attachment_fixture(note, %{
          id: unique_title("binary-attachment"),
          path: "files/blob.bin",
          mime: "application/octet-stream",
          description: "Binary bytes",
          object: bytes
        })

      expected = %{
        "id" => attachment.id,
        "path" => "./files/blob.bin",
        "mime" => "application/octet-stream",
        "description" => "Binary bytes",
        "content_url" =>
          "/api/gao_notes/#{note.id}/attachments/files/blob.bin",
        "content_base64" => Base.encode64(bytes)
      }

      for {server, frame} <- [
            {GSMLG.GaoNote.MCP.ReadOnlyServer, readonly_frame()},
            {GSMLG.GaoNote.MCP.AdminServer, admin_frame(actor())}
          ] do
        assert %{"structuredContent" => %{"attachment" => ^expected}} =
                 call_tool(
                   server,
                   "gao_note.get_attachment_with_content",
                   %{"note_id" => note.id, "attachment_id" => attachment.id},
                   frame
                 )
      end

      wrong_note = note_fixture(%{title: "Wrong owner"})

      assert %{"isError" => true} =
               call_tool(
                 GSMLG.GaoNote.MCP.ReadOnlyServer,
                 "gao_note.get_attachment_with_content",
                 %{"note_id" => wrong_note.id, "attachment_id" => attachment.id}
               )

      assert %{"isError" => true} =
               call_tool(
                 GSMLG.GaoNote.MCP.ReadOnlyServer,
                 "gao_note.get_attachment_with_content",
                 %{"note_id" => note.id, "attachment_id" => "missing-attachment"}
               )

      assert {:ok, _deleted} = GaoNote.delete_note(note, actor())

      assert %{"isError" => true} =
               call_tool(
                 GSMLG.GaoNote.MCP.ReadOnlyServer,
                 "gao_note.get_attachment_with_content",
                 %{"note_id" => note.id, "attachment_id" => attachment.id}
               )
    end

    test "resources/read returns note bodies" do
      note = note_fixture(%{title: "Readable Resource", content: "Resource content"})

      assert {:reply, response, _frame} =
               GSMLG.GaoNote.MCP.ReadOnlyServer.handle_request(
                 %{
                   "id" => 1,
                   "method" => "resources/read",
                   "params" => %{"uri" => "gaonote://notes/#{note.id}"}
                 },
                 readonly_frame()
               )

      assert %{"contents" => [%{"text" => "Resource content"}]} = response
    end

    test "mutating tools are unavailable" do
      refute "gao_note.create_note" in tool_names(GSMLG.GaoNote.MCP.ReadOnlyServer)
    end
  end

  describe "admin mode" do
    test "admin Backplane server registers the exact standalone attachment tools" do
      names = GSMLG.GaoNote.MCP.AdminServer |> tool_names() |> Enum.sort()

      assert names == ~w(
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

      refute "gao_note.list_attachments" in names
      refute Enum.any?(names, &String.starts_with?(&1, "gao_note.attachments."))
    end

    test "create tool exposes only create-note parameters" do
      tool = tool(GSMLG.GaoNote.MCP.AdminServer, "gao_note.create_note")

      assert tool_property_names(tool) == [
               "attachments",
               "content",
               "labels",
               "title"
             ]

      assert Enum.sort(tool.input_schema["required"]) == ["content", "title"]

      refute "color" in tool_property_names(tool)
      refute "attachment_id" in tool_property_names(tool)
      refute "limit" in tool_property_names(tool)
      refute "url" in tool_property_names(tool)
      refute "creator" in tool_property_names(tool)
    end

    test "update tool accepts only id, title, content, and labels" do
      tool = tool(GSMLG.GaoNote.MCP.AdminServer, "gao_note.update_note")

      assert tool_property_names(tool) == ~w(content id labels title)
      assert tool.input_schema["required"] == ["id"]
      assert tool.input_schema["additionalProperties"] == false
      refute Map.has_key?(tool.input_schema["properties"], "attachments")
    end

    test "requires an actor for mutating tools" do
      assert %{"isError" => true} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.create_note",
                 %{"title" => "No Actor", "content" => "x"},
                 admin_frame(nil)
               )
    end

    test "supports create, read, update, delete, and labels" do
      frame = admin_frame(actor())

      assert %{"structuredContent" => %{"note" => created}} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.create_note",
                 %{
                   "title" => "Admin MCP",
                   "content" => "MCP content"
                 },
                 frame
               )

      assert created["content"] == "MCP content"
      assert created["created_at"]
      refute Map.has_key?(created, "body")
      refute Map.has_key?(created, "body_format")
      refute Map.has_key?(created, "created_by_id")
      refute Map.has_key?(created, "updated_by_id")
      refute Map.has_key?(created, "metadata")
      refute Map.has_key?(created, "slug")
      refute Map.has_key?(created, "summary")
      refute Map.has_key?(created, "status")
      refute Map.has_key?(created, "visibility")

      assert %{"structuredContent" => %{"note" => fetched}} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.get",
                 %{"id" => created["id"]},
                 frame
               )

      assert fetched["id"] == created["id"]
      assert fetched["title"] == "Admin MCP"

      assert %{"structuredContent" => %{"note" => updated}} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.update_note",
                 %{
                   "id" => created["id"],
                   "title" => "Admin MCP Updated",
                   "content" => "Updated content"
                 },
                 frame
               )

      assert updated["title"] == "Admin MCP Updated"
      assert updated["content"] == "Updated content"

      assert %{"structuredContent" => %{"note" => labeled}} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.set_labels",
                 %{"id" => created["id"], "labels" => ["MCP", "Admin"]},
                 frame
               )

      assert Enum.map(labeled["labels"], &Map.take(&1, ["key", "value"])) == [
               %{"key" => "Admin", "value" => ""},
               %{"key" => "MCP", "value" => ""}
             ]

      assert %{"structuredContent" => %{"note" => deleted}} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.delete",
                 %{"id" => created["id"]},
                 frame
               )

      assert deleted["id"] == created["id"]
      assert GaoNote.get_note(created["id"]) == nil

      assert logs = GaoNote.list_logs(entity_type: "note", note_id: created["id"])
      assert Enum.any?(logs, &(&1.action == "create" and &1.source == "mcp"))
      assert Enum.any?(logs, &(&1.action == "update" and &1.source == "mcp"))
      assert Enum.any?(logs, &(&1.action == "delete" and &1.source == "mcp"))

      assert %{"isError" => true} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.get",
                 %{"id" => created["id"]},
                 frame
               )
    end

    test "supports creating label_settings explicitly" do
      frame = admin_frame(actor())

      assert %{"structuredContent" => %{"label_setting" => label_setting}} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.create_label_setting",
                 %{"name" => "agent-memory", "color" => "#1f6feb"},
                 frame
               )

      assert label_setting["name"] == "agent-memory"
      refute Map.has_key?(label_setting, "slug")
      assert label_setting["color"] == "#1f6feb"
    end

    test "create accepts non-ASCII label_setting names" do
      frame = admin_frame(actor())

      assert %{"structuredContent" => %{"note" => created}} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.create_note",
                 %{
                   "title" => "SpaceX 股价评价（X 搜索） - 2026-06-18",
                   "content" => "# SpaceX 股价评价（X 搜索） - 2026-06-18\n\n测试内容",
                   "labels" => ["投资观察", "X搜索", "SpaceX"]
                 },
                 frame
               )

      label_keys = created["labels"] |> Enum.map(& &1["key"]) |> Enum.sort()

      assert label_keys == ["SpaceX", "X搜索", "投资观察"]
      assert Enum.all?(created["labels"], &(&1["value"] == ""))
      refute Enum.any?(created["labels"], &Map.has_key?(&1, "slug"))
    end

    test "set_labels returns a tool error when labels is not an array" do
      frame = admin_frame(actor())
      note = note_fixture(%{title: "Invalid labels target"})

      assert %{"isError" => true, "content" => [%{"text" => message}]} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.set_labels",
                 %{"id" => note.id, "labels" => %{"name" => "agent-memory"}},
                 frame
               )

      assert message =~ "labels must be an array"
    end

    test "create makes initial attachments and field-only update preserves them" do
      frame = admin_frame(actor())
      attachment_id = unique_title("attachment")
      initial_bytes = "aggregate bytes"

      assert %{"structuredContent" => %{"note" => created}} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.create_note",
                 %{
                   "title" => unique_title("Aggregate"),
                   "content" => "See [data](./docs/data.txt)",
                   "attachments" => [
                     %{
                       "id" => attachment_id,
                       "path" => "docs/data.txt",
                       "mime" => "text/plain",
                       "description" => "MCP data",
                       "content" => initial_bytes
                     }
                   ]
                 },
                 frame
               )

      assert [
               %{
                 "id" => ^attachment_id,
                 "path" => "./docs/data.txt",
                 "mime" => "text/plain",
               "description" => "MCP data"
               } = attachment
             ] = created["attachments"]

      assert_attachment_metadata_only(attachment)
      assert_receive {:s3_put, _path, ^initial_bytes}

      persisted_before = Repo.get!(Attachment, attachment_id)

      assert %{"structuredContent" => %{"note" => updated}} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.update_note",
                 %{
                   "id" => created["id"],
                   "title" => "Aggregate retained",
                   "content" => "Updated body",
                   "labels" => ["scope=mcp"]
                 },
                 frame
               )

      assert updated["title"] == "Aggregate retained"
      assert updated["content"] == "Updated body"
      assert [%{"key" => "scope", "value" => "mcp"}] =
               Enum.map(updated["labels"], &Map.take(&1, ["key", "value"]))

      assert [%{"id" => ^attachment_id} = retained] = updated["attachments"]
      assert_attachment_metadata_only(retained)

      assert %Attachment{storage_file_id: storage_file_id} =
               Repo.get!(Attachment, attachment_id)

      assert storage_file_id == persisted_before.storage_file_id

      assert %{"isError" => true, "content" => [%{"text" => message}]} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.update_note",
                 %{"id" => created["id"], "attachments" => []},
                 frame
               )

      assert message =~ "unsupported note field: attachments"
      assert [%Attachment{id: ^attachment_id}] = GaoNote.get_note(created["id"]).attachments
    end

    test "aggregate attachment guard rejects legacy fields and invalid content forms" do
      frame = admin_frame(actor())

      base_attachment = %{
        "id" => unique_title("attachment"),
        "path" => "data.txt",
        "mime" => "text/plain",
        "content" => "data"
      }

      for legacy_field <- ~w(storage_file_id upload role caption alt_text position metadata) do
        attachment = Map.put(base_attachment, legacy_field, "forbidden")

        assert %{"isError" => true, "content" => [%{"text" => message}]} =
                 call_tool(
                   GSMLG.GaoNote.MCP.AdminServer,
                   "gao_note.create_note",
                   %{
                     "title" => unique_title("Rejected field"),
                     "content" => "body",
                     "attachments" => [attachment]
                   },
                   frame
                 )

        assert message =~ "unsupported attachment field"
      end

      assert %{"isError" => true, "content" => [%{"text" => both_message}]} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.create_note",
                 %{
                   "title" => unique_title("Both content forms"),
                   "content" => "body",
                   "attachments" => [
                     Map.put(base_attachment, "content_base64", Base.encode64("data"))
                   ]
                 },
                 frame
               )

      assert both_message =~ "only one of content or content_base64"

      missing_content = Map.delete(base_attachment, "content")

      assert %{"isError" => true, "content" => [%{"text" => missing_message}]} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.create_note",
                 %{
                   "title" => unique_title("Missing content"),
                   "content" => "body",
                   "attachments" => [missing_content]
                 },
                 frame
               )

      assert missing_message =~ "exactly one of content or content_base64"

      invalid_base64 =
        base_attachment
        |> Map.delete("content")
        |> Map.put("content_base64", "Zg")

      assert %{"isError" => true, "content" => [%{"text" => base64_message}]} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.create_note",
                 %{
                   "title" => unique_title("Invalid Base64"),
                   "content" => "body",
                   "attachments" => [invalid_base64]
                 },
                 frame
               )

      assert base64_message =~ "strict standard padded Base64"
    end

    test "put_attachment metadata-only updates preserve bytes and storage attribution" do
      original_bytes = "original attachment bytes"
      note = note_fixture(%{title: unique_title("Metadata put")})

      attachment =
        attachment_fixture(note, %{
          id: unique_title("metadata-put"),
          path: "original.txt",
          mime: "text/plain",
          description: "Original",
          object: original_bytes
        })

      args = %{
        "note_id" => note.id,
        "attachment_id" => attachment.id,
        "path" => "renamed.txt",
        "mime" => "text/plain",
        "description" => "Renamed",
        "update_content" => false
      }

      assert %{"isError" => true} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.put_attachment",
                 args,
                 admin_frame(nil)
               )

      assert %{"isError" => true} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.put_attachment",
                 Map.put(args, "mime", "application/json"),
                 admin_frame(actor())
               )

      _actor = actor()
      string_actor_frame = admin_frame(%{"id" => "admin-1"})

      assert %{"structuredContent" => %{"attachment" => updated}} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.put_attachment",
                 args,
                 string_actor_frame
               )

      assert updated["path"] == "./renamed.txt"
      assert updated["description"] == "Renamed"
      assert_attachment_metadata_only(updated)

      assert %Attachment{storage_file_id: storage_file_id} =
               Repo.get!(Attachment, attachment.id)

      assert storage_file_id == attachment.storage_file_id
      set_storage_object(original_bytes)

      assert %{
               "structuredContent" => %{
                 "attachment" => %{"content_base64" => encoded}
               }
             } =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.get_attachment_with_content",
                 %{"note_id" => note.id, "attachment_id" => attachment.id},
                 string_actor_frame
               )

      assert encoded == Base.encode64(original_bytes)

      assert %Log{
               action: "update",
               entity_type: "attachment",
               entity_id: entity_id,
               note_id: note_id,
               actor_id: "admin-1",
               source: "mcp",
               details: %{"content_updated" => false}
             } =
               Repo.get_by!(Log,
                 entity_type: "attachment",
                 entity_id: attachment.id,
                 action: "update"
               )

      assert entity_id == attachment.id
      assert note_id == note.id
    end

    test "put_attachment replaces bytes from raw and strict padded Base64 content" do
      note = note_fixture(%{title: unique_title("Content put")})

      attachment =
        attachment_fixture(note, %{
          id: unique_title("content-put"),
          path: "content.txt",
          mime: "text/plain",
          description: "Original",
          object: "original"
        })

      frame = admin_frame(actor())
      raw_bytes = "raw replacement bytes"

      assert %{"structuredContent" => %{"attachment" => raw_updated}} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.put_attachment",
                 %{
                   "note_id" => note.id,
                   "attachment_id" => attachment.id,
                   "path" => "raw.txt",
                   "mime" => "text/plain",
                   "description" => "Raw replacement",
                   "update_content" => true,
                   "content" => raw_bytes
                 },
                 frame
               )

      assert raw_updated["path"] == "./raw.txt"
      assert_attachment_metadata_only(raw_updated)
      assert_receive {:s3_put, _path, ^raw_bytes}

      raw_storage_file_id = Repo.get!(Attachment, attachment.id).storage_file_id
      refute raw_storage_file_id == attachment.storage_file_id

      base64_bytes = "base64 byte"
      padded_base64 = Base.encode64(base64_bytes)
      assert String.ends_with?(padded_base64, "=")

      assert %{"structuredContent" => %{"attachment" => base64_updated}} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.put_attachment",
                 %{
                   "note_id" => note.id,
                   "attachment_id" => attachment.id,
                   "path" => "encoded.txt",
                   "mime" => "text/plain",
                   "description" => "Base64 replacement",
                   "update_content" => true,
                   "content_base64" => padded_base64
                 },
                 frame
               )

      assert base64_updated["path"] == "./encoded.txt"
      assert_attachment_metadata_only(base64_updated)
      assert_receive {:s3_put, _path, ^base64_bytes}

      base64_storage_file_id = Repo.get!(Attachment, attachment.id).storage_file_id
      refute base64_storage_file_id in [attachment.storage_file_id, raw_storage_file_id]

      set_storage_object(base64_bytes)

      assert %{
               "structuredContent" => %{
                 "attachment" => %{"content_base64" => ^padded_base64}
               }
             } =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.get_attachment_with_content",
                 %{"note_id" => note.id, "attachment_id" => attachment.id},
                 frame
               )
    end

    test "put_attachment schema and runtime reject the strict content matrix and MIME mismatch" do
      note = note_fixture(%{title: unique_title("Rejected put")})

      attachment =
        attachment_fixture(note, %{
          id: unique_title("rejected-put"),
          path: "data.txt",
          mime: "text/plain",
          object: "original"
        })

      frame = admin_frame(actor())

      base = %{
        "note_id" => note.id,
        "attachment_id" => attachment.id,
        "path" => "data.txt",
        "mime" => "text/plain",
        "description" => "Data"
      }

      invalid_cases = [
        {Map.merge(base, %{"update_content" => false, "content" => "forbidden"}), "forbids"},
        {Map.put(base, "update_content", true), "requires exactly one"},
        {Map.merge(base, %{
           "update_content" => true,
           "content" => "raw",
           "content_base64" => Base.encode64("raw")
         }), "requires exactly one"},
        {Map.merge(base, %{"update_content" => true, "content_base64" => "Zg"}),
         "strict standard padded Base64"}
      ]

      schema = GSMLG.GaoNote.MCP.Tools.PutAttachment.__mcp_raw_schema__()

      for {args, expected_message} <- invalid_cases do
        assert {:error, _errors} = Peri.validate(schema, args)

        assert %{"isError" => true, "content" => [%{"text" => message}]} =
                 call_tool(
                   GSMLG.GaoNote.MCP.AdminServer,
                   "gao_note.put_attachment",
                   args,
                   frame
                 )

        assert message =~ expected_message
      end

      mime_mismatch =
        Map.merge(base, %{
          "update_content" => true,
          "mime" => "application/json",
          "content" => "plain text"
        })

      assert {:ok, _args} = Peri.validate(schema, mime_mismatch)

      assert %{"isError" => true, "content" => [%{"text" => mime_message}]} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.put_attachment",
                 mime_mismatch,
                 frame
               )

      assert mime_message =~ "mime_mismatch"
      assert Repo.get!(Attachment, attachment.id).storage_file_id == attachment.storage_file_id
    end

    test "put and delete reject wrong ownership and delete only the selected attachment" do
      note = note_fixture(%{title: unique_title("Delete selected")})
      other_note = note_fixture(%{title: unique_title("Other owner")})

      selected =
        attachment_fixture(note, %{
          id: unique_title("selected"),
          path: "selected.txt",
          mime: "text/plain",
          description: "Selected",
          object: "selected"
        })

      retained =
        attachment_fixture(note, %{
          id: unique_title("retained"),
          path: "retained.txt",
          mime: "text/plain",
          description: "Retained",
          object: "retained"
        })

      put_args = %{
        "note_id" => other_note.id,
        "attachment_id" => selected.id,
        "path" => "selected.txt",
        "mime" => "text/plain",
        "description" => "Wrong owner",
        "update_content" => false
      }

      frame = admin_frame(actor())

      assert %{"isError" => true} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.put_attachment",
                 put_args,
                 frame
               )

      assert %{"isError" => true} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.put_attachment",
                 %{put_args | "note_id" => note.id, "attachment_id" => "missing-attachment"},
                 frame
               )

      delete_args = %{"note_id" => note.id, "attachment_id" => selected.id}

      assert %{"isError" => true} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.delete_attachment",
                 delete_args,
                 admin_frame(nil)
               )

      assert %{"isError" => true} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.delete_attachment",
                 %{"note_id" => other_note.id, "attachment_id" => selected.id},
                 frame
               )

      assert %{"isError" => true} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.delete_attachment",
                 %{"note_id" => note.id, "attachment_id" => "missing-attachment"},
                 frame
               )

      _actor = actor()
      string_actor_frame = admin_frame(%{"id" => "admin-1"})

      assert %{"structuredContent" => %{"attachment" => deleted}} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.delete_attachment",
                 delete_args,
                 string_actor_frame
               )

      assert deleted["id"] == selected.id
      assert_attachment_metadata_only(deleted)
      assert Repo.get(Attachment, selected.id) == nil
      assert %Attachment{id: retained_id} = Repo.get(Attachment, retained.id)
      assert retained_id == retained.id

      assert %Log{
               action: "delete",
               entity_type: "attachment",
               entity_id: entity_id,
               note_id: note_id,
               actor_id: "admin-1",
               source: "mcp"
             } =
               Repo.get_by!(Log,
                 entity_type: "attachment",
                 entity_id: selected.id,
                 action: "delete"
               )

      assert entity_id == selected.id
      assert note_id == note.id
    end

    test "set_labels remains labels-only and succeeds without attachments" do
      frame = admin_frame(actor())
      note = note_fixture(%{title: unique_title("Labels only")})

      assert %{"structuredContent" => %{"note" => labeled}} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.set_labels",
                 %{"id" => note.id, "labels" => ["scope=mcp"]},
                 frame
               )

      assert [%{"key" => "scope", "value" => "mcp"}] =
               Enum.map(labeled["labels"], &Map.take(&1, ["key", "value"]))
    end
  end

  defp tool_names(server) do
    server.__components__(:tool)
    |> Enum.map(& &1.name)
  end

  defp tool(server, name) do
    server.__components__(:tool)
    |> Enum.find(&(&1.name == name))
  end

  defp tool_property_names(tool) do
    tool.input_schema
    |> Map.fetch!("properties")
    |> Map.keys()
    |> Enum.sort()
  end

  defp call_tool(server, name, args, frame \\ readonly_frame()) do
    tool = tool(server, name)

    assert tool
    assert {:reply, %Response{} = response, _frame} = tool.handler.execute(args, frame)
    Response.to_protocol(response)
  end

  defp readonly_frame, do: Frame.new(%{mode: :readonly})
  defp admin_frame(actor), do: Frame.new(%{mode: :admin, actor: actor})

  defp assert_note_attachment_metadata(note, attachment_id) do
    assert [%{"id" => ^attachment_id} = attachment] = note["attachments"]
    assert_attachment_metadata_only(attachment)
  end

  defp assert_attachment_metadata_only(attachment) do
    assert attachment |> Map.keys() |> Enum.sort() == @attachment_metadata_keys
  end

  defp set_storage_object(bytes) do
    Application.put_env(:gsmlg_storage, :gao_note_mcp_test_object, bytes)
  end

  defp actor do
    unless Repo.get(User, "admin-1") do
      Repo.insert!(%User{
        id: "admin-1",
        username: "admin-1",
        email: "admin-1@example.test",
        password: "test"
      })
    end

    %{id: "admin-1"}
  end

  defp note_fixture(attrs) do
    attrs =
      Map.merge(
        %{title: unique_title("Note"), content: "Content"},
        attrs
      )

    assert {:ok, note} = GaoNote.create_note(attrs, actor())
    note
  end

  defp attachment_fixture(note, attrs) do
    object = Map.fetch!(attrs, :object)
    path = Map.fetch!(attrs, :path)
    mime = Map.fetch!(attrs, :mime)
    set_storage_object(object)

    file =
      %StorageFile{}
      |> StorageFile.changeset(%{
        tenant: note.id,
        type: "gao_note_attachment",
        filename: Path.basename(path),
        s3_key: "gao_note/#{Ecto.UUID.generate()}",
        content_type: mime,
        size: byte_size(object),
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
        id: Map.fetch!(attrs, :id),
        note_id: note.id,
        storage_file_id: file.id,
        path: path,
        mime: mime,
        description: Map.get(attrs, :description, "")
      })
      |> Repo.insert!()

    Repo.preload(attachment, :storage_file)
  end

  defp unique_title(prefix) do
    "#{prefix} #{System.unique_integer([:positive])}"
  end
end
