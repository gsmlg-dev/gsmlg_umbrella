defmodule GSMLG.GaoNote.MCPTest do
  use GSMLG.GaoNote.DataCase, async: false

  alias Backplane.McpProtocol.Server.{Frame, Response}
  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{Asset, Log, MCPSetting, Note, Reference, Tag, Tagging}
  alias GSMLG.Accounts.User
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

  describe "readonly mode" do
    test "read-only Backplane server registers read-only tools only" do
      names = tool_names(GSMLG.GaoNote.MCP.ReadOnlyServer)

      assert "gao_note.search" in names
      assert "gao_note.get" in names
      assert "gao_note.list_tags" in names
      refute "gao_note.create" in names
      refute "gao_note.delete" in names
      refute "gao_note.assets.upload_base64" in names
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
      refute "gao_note.create" in tool_names(GSMLG.GaoNote.MCP.ReadOnlyServer)
    end
  end

  describe "admin mode" do
    test "admin Backplane server registers CRUD tools" do
      names = tool_names(GSMLG.GaoNote.MCP.AdminServer)

      assert "gao_note.create" in names
      assert "gao_note.create_tag" in names
      assert "gao_note.delete" in names
      assert "gao_note.assets.upload_base64" in names
      refute "gao_note.publish" in names
      refute "gao_note.archive" in names
    end

    test "create tool tells agents to set creator to the writer name" do
      tool = tool(GSMLG.GaoNote.MCP.AdminServer, "gao_note.create")
      creator_schema = tool.input_schema["properties"]["creator"]

      assert tool.description =~ "set creator to the agent name"
      assert creator_schema["description"] =~ "agent writing the note"
    end

    test "create tool exposes only create-note parameters" do
      tool = tool(GSMLG.GaoNote.MCP.AdminServer, "gao_note.create")

      assert tool_property_names(tool) == [
               "content",
               "creator",
               "description",
               "tags",
               "title"
             ]

      assert Enum.sort(tool.input_schema["required"]) == ["content", "title"]

      refute "color" in tool_property_names(tool)
      refute "asset_id" in tool_property_names(tool)
      refute "limit" in tool_property_names(tool)
      refute "url" in tool_property_names(tool)
    end

    test "requires an actor for mutating tools" do
      assert %{"isError" => true} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.create",
                 %{"title" => "No Actor", "description" => "x", "content" => "x"},
                 admin_frame(nil)
               )
    end

    test "supports create, read, update, delete, tags, and references" do
      frame = admin_frame(actor())

      assert %{"structuredContent" => %{"note" => created}} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.create",
                 %{
                   "title" => "Admin MCP",
                   "description" => "MCP description",
                   "content" => "MCP content",
                   "creator" => "note-agent"
                 },
                 frame
               )

      assert created["description"] == "MCP description"
      assert created["content"] == "MCP content"
      assert created["creator"] == "note-agent"
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
                 "gao_note.update",
                 %{
                   "id" => created["id"],
                   "title" => "Admin MCP Updated",
                   "description" => "Updated description",
                   "content" => "Updated content"
                 },
                 frame
               )

      assert updated["title"] == "Admin MCP Updated"
      assert updated["description"] == "Updated description"
      assert updated["content"] == "Updated content"

      assert %{"structuredContent" => %{"note" => tagged}} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.set_tags",
                 %{"id" => created["id"], "tags" => ["MCP", "Admin"]},
                 frame
               )

      assert Enum.map(tagged["tags"], & &1["name"]) == ["Admin", "MCP"]

      assert %{"structuredContent" => %{"reference" => reference}} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.references.add",
                 %{"id" => created["id"], "url" => "https://example.com/ref"},
                 frame
               )

      assert reference["url"] == "https://example.com/ref"

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

    test "supports creating tags explicitly" do
      frame = admin_frame(actor())

      assert %{"structuredContent" => %{"tag" => tag}} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.create_tag",
                 %{"name" => "agent-memory", "color" => "#1f6feb"},
                 frame
               )

      assert tag["name"] == "agent-memory"
      refute Map.has_key?(tag, "slug")
      assert tag["color"] == "#1f6feb"
    end

    test "create accepts non-ASCII tag names" do
      frame = admin_frame(actor())

      assert %{"structuredContent" => %{"note" => created}} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.create",
                 %{
                   "title" => "SpaceX 股价评价（X 搜索） - 2026-06-18",
                   "content" => "# SpaceX 股价评价（X 搜索） - 2026-06-18\n\n测试内容",
                   "creator" => "Aoi",
                   "tags" => ["投资观察", "X搜索", "SpaceX"]
                 },
                 frame
               )

      tag_names = created["tags"] |> Enum.map(& &1["name"]) |> Enum.sort()

      assert tag_names == ["SpaceX", "X搜索", "投资观察"]
      refute Enum.any?(created["tags"], &Map.has_key?(&1, "slug"))
    end

    test "set_tags returns a tool error when tags is not an array" do
      frame = admin_frame(actor())
      note = note_fixture(%{title: "Invalid tags target"})

      assert %{"isError" => true, "content" => [%{"text" => message}]} =
               call_tool(
                 GSMLG.GaoNote.MCP.AdminServer,
                 "gao_note.set_tags",
                 %{"id" => note.id, "tags" => %{"name" => "agent-memory"}},
                 frame
               )

      assert message =~ "tags must be an array of strings"
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
        %{title: unique_title("Note"), description: "Description", content: "Content"},
        attrs
      )

    assert {:ok, note} = GaoNote.create_note(attrs, actor())
    note
  end

  defp unique_title(prefix) do
    "#{prefix} #{System.unique_integer([:positive])}"
  end
end
