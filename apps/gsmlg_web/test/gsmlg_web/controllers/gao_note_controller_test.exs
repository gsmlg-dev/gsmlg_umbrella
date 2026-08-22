defmodule GSMLG.Web.GaoNoteControllerTest do
  use GSMLG.Web.ConnCase, async: false

  alias GSMLG.Accounts.User
  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{Attachment, Label, LabelSetting, Log, Note}
  alias GSMLG.Repo
  alias GSMLG.Storage.StorageFile

  setup %{conn: conn} do
    Repo.delete_all(Log)
    Repo.delete_all(Attachment)
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

  describe "removed aggregate-fragment routes" do
    test "reference and asset collections return 404", %{conn: conn} do
      note = note_fixture()

      for path <- [
            "/api/gao_notes/#{note.id}/references",
            "/api/gao_notes/#{note.id}/assets"
          ] do
        response =
          conn
          |> recycle()
          |> get(path)
          |> json_response(404)

        assert response == %{"errors" => %{"detail" => "Not Found"}}
      end

      controller_functions = GSMLG.Web.GaoNoteController.__info__(:functions)
      json_functions = GSMLG.Web.GaoNoteJSON.__info__(:functions)

      refute {:references, 2} in controller_functions
      refute {:assets, 2} in controller_functions
      refute {:references, 1} in json_functions
      refute {:assets, 1} in json_functions
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
          content: "Content"
        },
        attrs
      )

    assert {:ok, note} = GaoNote.create_note(attrs, actor())
    note
  end
end
