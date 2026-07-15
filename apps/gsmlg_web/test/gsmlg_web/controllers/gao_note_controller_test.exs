defmodule GSMLG.Web.GaoNoteControllerTest do
  use GSMLG.Web.ConnCase, async: false

  alias GSMLG.Accounts.User
  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{Asset, Label, LabelSetting, Note, Reference}
  alias GSMLG.Repo
  alias GSMLG.Storage.StorageFile

  setup %{conn: conn} do
    Repo.delete_all(Asset)
    Repo.delete_all(Reference)
    Repo.delete_all(Label)
    Repo.delete_all(LabelSetting)
    Repo.delete_all(Note)
    Repo.delete_all(StorageFile)

    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "index" do
    test "lists GaoNote notes through the public API", %{conn: conn} do
      _other_note = note_fixture(%{title: "Other Memory"})
      note = note_fixture(%{title: "Public Memory", labels: ["Research", "Elixir"]})

      conn = get(conn, ~p"/api/gao_notes", %{"search" => "Public", "label" => "research"})

      assert %{"data" => [rendered]} = json_response(conn, 200)
      assert rendered["id"] == note.id
      assert rendered["title"] == "Public Memory"
      assert rendered["description"] == "Description"
      assert rendered["content"] == "Content"

      assert [
               %{"key" => "Elixir", "value" => ""},
               %{"key" => "Research", "value" => ""}
             ] = rendered["labels"]

      refute Map.has_key?(rendered, "creator")
      assert rendered["created_at"]
      assert rendered["updated_at"]
      refute Map.has_key?(rendered, "body")
      refute Map.has_key?(rendered, "created_by_id")
      refute Map.has_key?(rendered, "metadata")
      refute Map.has_key?(rendered, "visibility")
    end
  end

  describe "show" do
    test "returns a GaoNote note by id", %{conn: conn} do
      note = note_fixture(%{title: "Readable Note"})

      conn = get(conn, ~p"/api/gao_notes/#{note.id}")

      assert %{"data" => rendered} = json_response(conn, 200)
      assert rendered["id"] == note.id
      assert rendered["title"] == "Readable Note"
    end

    test "returns 404 for an unknown GaoNote id", %{conn: conn} do
      conn = get(conn, ~p"/api/gao_notes/#{Ecto.UUID.generate()}")

      assert %{"errors" => %{"detail" => "Not Found"}} = json_response(conn, 404)
    end
  end

  describe "label settings" do
    test "lists GaoNote label settings", %{conn: conn} do
      _note = note_fixture(%{labels: ["Research"]})

      conn = get(conn, ~p"/api/gao_notes/label_settings")

      assert %{"data" => [%{"name" => "Research", "metadata" => %{}}]} = json_response(conn, 200)
    end
  end

  describe "references" do
    test "lists references for a GaoNote note", %{conn: conn} do
      note = note_fixture()

      assert {:ok, reference} =
               GaoNote.add_reference(
                 note,
                 %{url: "https://example.com/story?utm_source=test", title: "Example"},
                 actor()
               )

      conn = get(conn, ~p"/api/gao_notes/#{note.id}/references")

      assert %{"data" => [rendered]} = json_response(conn, 200)
      assert rendered["id"] == reference.id
      assert rendered["note_id"] == note.id
      assert rendered["url"] == "https://example.com/story?utm_source=test"
      assert rendered["canonical_url"] == "https://example.com/story"
      assert rendered["title"] == "Example"
    end
  end

  describe "assets" do
    test "lists active public assets for a GaoNote note", %{conn: conn} do
      note = note_fixture()
      file = storage_file_fixture(%{metadata: %{"visibility" => "public"}})

      assert {:ok, asset} =
               GaoNote.attach_asset(note, file.id, %{role: "cover", caption: "Cover"}, actor())

      conn = get(conn, ~p"/api/gao_notes/#{note.id}/assets")

      assert %{"data" => [rendered]} = json_response(conn, 200)
      assert rendered["id"] == asset.id
      assert rendered["note_id"] == note.id
      assert rendered["storage_file_id"] == file.id
      assert rendered["role"] == "cover"
      assert rendered["caption"] == "Cover"
      assert rendered["url"] == "/files/#{file.id}"
      assert rendered["storage_file"]["filename"] == "gao-note.txt"
    end
  end

  defp actor do
    unless Repo.get(User, "public-api-test") do
      Repo.insert!(%User{
        id: "public-api-test",
        username: "public-api-test",
        email: "public-api-test@example.test",
        password: "test"
      })
    end

    %{id: "public-api-test"}
  end

  defp note_fixture(attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          title: "Public API #{System.unique_integer([:positive])}",
          description: "Description",
          content: "Content"
        },
        attrs
      )

    assert {:ok, note} = GaoNote.create_note(attrs, actor())
    note
  end

  defp storage_file_fixture(attrs) do
    attrs =
      Map.merge(
        %{
          tenant: "gao_note",
          type: "asset",
          filename: "gao-note.txt",
          s3_key: "gao_note/asset/#{Ecto.UUID.generate()}.txt",
          content_type: "text/plain",
          size: 32,
          checksum: "checksum",
          metadata: %{},
          status: "active",
          uploaded_by: "public-api-test"
        },
        attrs
      )

    %StorageFile{}
    |> StorageFile.changeset(attrs)
    |> Repo.insert!()
  end
end
