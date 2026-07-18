defmodule GSMLG.GaoNote.MCPTest do
  use GSMLG.GaoNote.DataCase, async: false

  alias Backplane.McpProtocol.Server.{Frame, Response}
  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{Attachment, Label, LabelSetting, Log, MCPSetting, Note}
  alias GSMLG.Accounts.User
  alias GSMLG.Storage.StorageFile

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

  describe "readonly mode" do
    test "read-only Backplane server registers read-only tools only" do
      names = tool_names(GSMLG.GaoNote.MCP.ReadOnlyServer)

      assert "gao_note.search" in names
      assert "gao_note.get" in names
      assert "gao_note.list_label_settings" in names
      refute "gao_note.list_attachments" in names
      refute "gao_note.list_references" in names
      refute "gao_note.list_assets" in names
      refute "gao_note.create_note" in names
      refute "gao_note.delete" in names
      refute Enum.any?(names, &String.contains?(&1, "attachment"))
    end

    test "search and get return notes without publishing metadata" do
      created_note = note_fixture(%{title: "MCP Public"})

      assert %{"structuredContent" => %{"notes" => [note]}} =
               call_tool(GSMLG.GaoNote.MCP.ReadOnlyServer, "gao_note.search", %{"query" => "MCP"})

      assert note["id"] == created_note.id
      assert note["title"] == "MCP Public"
      refute Map.has_key?(note, "slug")
      refute Map.has_key?(note, "summary")
      refute Map.has_key?(note, "status")
      refute Map.has_key?(note, "visibility")

      assert %{"isError" => true} =
               call_tool(GSMLG.GaoNote.MCP.ReadOnlyServer, "gao_note.get", %{
                 "id" => note["id"] <> "-missing"
               })
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
    test "admin Backplane server registers CRUD tools" do
      names = tool_names(GSMLG.GaoNote.MCP.AdminServer)

      assert "gao_note.create_note" in names
      assert "gao_note.create_label_setting" in names
      assert "gao_note.update_note" in names
      assert "gao_note.delete" in names
      refute "gao_note.list_attachments" in names
      refute Enum.any?(names, &String.contains?(&1, "attachment"))
      refute "gao_note.references.add" in names
      refute "gao_note.assets.upload_base64" in names
      refute "gao_note.publish" in names
      refute "gao_note.archive" in names
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
                   "content" => "Updated content",
                   "attachments" => []
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

    test "create and update forward aggregate attachments without exposing bytes" do
      frame = admin_frame(actor())
      attachment_id = unique_title("attachment")

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
                       "content" => "aggregate bytes"
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

      assert Map.keys(attachment) |> Enum.sort() ==
               ~w(content_url description id mime path)

      retained = Map.take(attachment, ~w(id path mime description))

      assert %{"structuredContent" => %{"note" => updated}} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.update_note",
                 %{
                   "id" => created["id"],
                   "title" => "Aggregate retained",
                   "attachments" => [retained]
                 },
                 frame
               )

      assert [%{"id" => ^attachment_id, "path" => "./docs/data.txt"}] =
               updated["attachments"]
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

  defp unique_title(prefix) do
    "#{prefix} #{System.unique_integer([:positive])}"
  end
end
