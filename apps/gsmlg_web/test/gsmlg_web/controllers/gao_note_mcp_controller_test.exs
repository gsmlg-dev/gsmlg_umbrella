defmodule GSMLG.Web.GaoNoteMCPControllerTest do
  use GSMLG.Web.ConnCase, async: false

  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{Asset, Note, Reference, Tag, Tagging}
  alias GSMLG.Accounts.User
  alias GSMLG.Repo
  alias GSMLG.Storage.StorageFile

  setup do
    Repo.delete_all(Asset)
    Repo.delete_all(Reference)
    Repo.delete_all(Tagging)
    Repo.delete_all(Tag)
    Repo.delete_all(Note)
    Repo.delete_all(StorageFile)
    :ok
  end

  test "public MCP initialize is handled by Backplane Streamable HTTP", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> post(~p"/mcp/gao_note", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "gao-note-test", "version" => "0.1.0"}
        }
      })

    assert [_session_id] = get_resp_header(conn, "mcp-session-id")

    assert %{
             "result" => %{
               "serverInfo" => %{"name" => "gsmlg-gao-note-readonly"},
               "capabilities" => %{"tools" => %{}, "resources" => %{}}
             }
           } = json_response(conn, 200)
  end

  test "public MCP tools/list exposes readonly tools only", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> post(~p"/mcp/gao_note", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{}
      })

    names = conn |> json_response(200) |> get_in(["result", "tools"]) |> Enum.map(& &1["name"])

    assert "gao_note.search" in names
    assert "gao_note.get" in names
    refute "gao_note.create" in names
    refute "gao_note.assets.upload_base64" in names
  end

  test "public MCP search returns notes without publishing metadata", %{conn: conn} do
    created_note = note_fixture(%{title: "MCP Visible"})

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> post(~p"/mcp/gao_note", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "gao_note.search",
          "arguments" => %{"query" => "MCP"}
        }
      })

    assert %{"result" => %{"structuredContent" => %{"notes" => [note]}}} =
             json_response(conn, 200)

    assert note["id"] == created_note.id
    assert note["title"] == "MCP Visible"
    assert note["description"] == "Description"
    assert note["content"] == "Content"
    assert note["creator"] == "public-test"
    assert note["created_at"]
    refute Map.has_key?(note, "body")
    refute Map.has_key?(note, "body_format")
    refute Map.has_key?(note, "created_by_id")
    refute Map.has_key?(note, "updated_by_id")
    refute Map.has_key?(note, "metadata")
    refute Map.has_key?(note, "slug")
    refute Map.has_key?(note, "summary")
    refute Map.has_key?(note, "status")
    refute Map.has_key?(note, "visibility")
  end

  defp actor do
    unless Repo.get(User, "public-test") do
      Repo.insert!(%User{
        id: "public-test",
        username: "public-test",
        email: "public-test@example.test",
        password: "test"
      })
    end

    %{id: "public-test"}
  end

  defp note_fixture(attrs) do
    attrs =
      Map.merge(
        %{
          title: "Draft #{System.unique_integer([:positive])}",
          description: "Description",
          creator: "public-test",
          content: "Content"
        },
        attrs
      )

    assert {:ok, note} = GaoNote.create_note(attrs, actor())
    note
  end
end
