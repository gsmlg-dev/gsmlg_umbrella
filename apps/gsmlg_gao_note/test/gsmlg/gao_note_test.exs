defmodule GSMLG.GaoNoteTest do
  use GSMLG.GaoNote.DataCase, async: false

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

  describe "notes" do
    test "create_note/2 stores only the note fields requested by the domain" do
      assert {:ok, %Note{} = note} =
               GaoNote.create_note(
                 %{
                   title: "Hello, World!",
                   description: "Short context",
                   content: "# Content",
                   body: "ignored",
                   body_format: "markdown",
                   created_by_id: "ignored",
                   updated_by_id: "ignored",
                   metadata: %{"ignored" => true},
                   slug: "ignored",
                   summary: "ignored",
                   status: "published",
                   visibility: "public",
                   creator: "note-agent"
                 },
                 actor()
               )

      assert note.title == "Hello, World!"
      assert note.description == "Short context"
      assert note.content == "# Content"
      assert note.creator == "note-agent"
      assert %DateTime{} = note.created_at
      assert %DateTime{} = note.updated_at

      refute Map.has_key?(note, :body)
      refute Map.has_key?(note, :body_format)
      refute Map.has_key?(note, :created_by_id)
      refute Map.has_key?(note, :updated_by_id)
      refute Map.has_key?(note, :metadata)
      refute Map.has_key?(note, :slug)
      refute Map.has_key?(note, :summary)
      refute Map.has_key?(note, :status)
      refute Map.has_key?(note, :visibility)

      rendered = GSMLG.GaoNote.Presenter.note(note)
      assert rendered["title"] == "Hello, World!"
      assert rendered["description"] == "Short context"
      assert rendered["content"] == "# Content"
      assert rendered["creator"] == "note-agent"
      assert rendered["created_at"]
      assert rendered["updated_at"]

      refute Map.has_key?(rendered, "body")
      refute Map.has_key?(rendered, "body_format")
      refute Map.has_key?(rendered, "created_by_id")
      refute Map.has_key?(rendered, "updated_by_id")
      refute Map.has_key?(rendered, "metadata")
      refute Map.has_key?(rendered, "slug")
      refute Map.has_key?(rendered, "summary")
      refute Map.has_key?(rendered, "status")
      refute Map.has_key?(rendered, "visibility")
    end

    test "allows description to be omitted" do
      assert {:ok, %Note{} = note} =
               GaoNote.create_note(
                 %{title: unique_title("No Description"), content: "Content without description"},
                 actor()
               )

      assert note.title =~ "No Description"
      assert note.description in [nil, ""]
      assert note.content == "Content without description"
    end

    test "defaults creator to empty when omitted" do
      assert {:ok, %Note{} = note} =
               GaoNote.create_note(
                 %{title: unique_title("No Creator"), content: "Content without creator"},
                 actor()
               )

      assert note.creator == ""
    end

    test "requires title and content only" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               GaoNote.create_note(
                 %{title: "", description: "", content: ""},
                 nil
               )

      refute changeset.valid?

      errors = errors_on(changeset)

      assert %{title: [_ | _], content: [_ | _]} = errors
      refute Map.has_key?(errors, :creator)
      refute Map.has_key?(errors, :description)
    end

    test "create, read, update, and delete note lifecycle" do
      note = note_fixture()
      note_id = note.id

      assert %Note{id: ^note_id} = GaoNote.get_note(note_id)
      assert %Note{id: ^note_id} = GaoNote.get_note!(note_id)
      assert %Note{id: ^note_id} = GaoNote.get_public_note(note_id)

      assert {:ok, %Note{} = updated} =
               GaoNote.update_note(
                 note,
                 %{
                   title: "Renamed",
                   description: "Updated description",
                   content: "Updated content",
                   creator: "Renamed Creator",
                   body: "ignored",
                   body_format: "ignored",
                   created_by_id: "ignored",
                   updated_by_id: "ignored",
                   metadata: %{"ignored" => true},
                   slug: "ignored",
                   summary: "ignored",
                   status: "archived",
                   visibility: "private"
                 },
                 actor("actor-2")
               )

      assert updated.title == "Renamed"
      assert updated.description == "Updated description"
      assert updated.content == "Updated content"
      assert updated.creator == "Renamed Creator"

      refute Map.has_key?(updated, :body)
      refute Map.has_key?(updated, :body_format)
      refute Map.has_key?(updated, :created_by_id)
      refute Map.has_key?(updated, :updated_by_id)
      refute Map.has_key?(updated, :metadata)
      refute Map.has_key?(updated, :slug)
      refute Map.has_key?(updated, :summary)
      refute Map.has_key?(updated, :status)
      refute Map.has_key?(updated, :visibility)

      assert %Note{title: "Renamed", content: "Updated content"} = GaoNote.get_note(note_id)

      assert {:ok, %Note{}} = GaoNote.delete_note(updated, actor())
      assert GaoNote.get_note(note_id) == nil
      assert GaoNote.get_public_note(note_id) == nil
    end

    test "list/search options return notes by search text" do
      _other = note_fixture(%{title: "Needle Other"})
      public = note_fixture(%{title: "Needle Public"})
      unlisted = note_fixture(%{title: "Needle Unlisted"})

      public_ids =
        GaoNote.list_notes()
        |> Enum.map(& &1.id)

      assert public.id in public_ids
      assert unlisted.id in public_ids
      assert length(public_ids) == 3

      assert [%Note{id: id}] = GaoNote.search_notes("Public")
      assert id == public.id
    end
  end

  describe "logs" do
    test "records create, update, and delete note actions" do
      assert {:ok, note} =
               GaoNote.create_note(
                 %{title: "Logged Note", content: "Logged content"},
                 actor("logger-1")
               )

      assert {:ok, updated} =
               GaoNote.update_note(
                 note,
                 %{title: "Logged Note Updated", content: "Updated content"},
                 actor("logger-2")
               )

      assert {:ok, _deleted} = GaoNote.delete_note(updated, actor("logger-3"))

      assert [delete_log, update_log, create_log] =
               GaoNote.list_logs(entity_type: "note", note_id: note.id)

      assert %Log{
               action: "delete",
               actor_id: "logger-3",
               source: "admin",
               details: %{"title" => "Logged Note Updated"}
             } = delete_log

      assert %Log{
               action: "update",
               actor_id: "logger-2",
               details: %{"fields" => fields, "title" => "Logged Note Updated"}
             } = update_log

      assert Enum.sort(fields) == ["content", "title"]

      assert %Log{
               action: "create",
               actor_id: "logger-1",
               details: %{"title" => "Logged Note"}
             } = create_log
    end
  end

  describe "mcp settings" do
    test "sets and verifies the GaoNote MCP API key" do
      api_key = GaoNote.generate_mcp_api_key()

      assert String.starts_with?(api_key, "gnmcp_")
      assert {:ok, %MCPSetting{} = setting} = GaoNote.set_mcp_api_key(api_key, actor("mcp-key"))
      assert setting.api_key_hint =~ "gnmcp_"
      refute setting.api_key_hash == api_key

      assert {:ok, %{id: "mcp-key", source: "mcp_api_key"}} =
               GaoNote.verify_mcp_api_key(api_key)

      assert :error = GaoNote.verify_mcp_api_key("wrong")
    end
  end

  describe "tags" do
    test "create, read, update, and delete tag lifecycle" do
      assert {:ok, %Tag{name: "Research", slug: "research"} = tag} =
               GaoNote.create_tag(%{name: "  Research  ", color: "#1f6feb"})

      tag_id = tag.id

      assert %Tag{id: ^tag_id, name: "Research"} = GaoNote.get_tag(tag_id)
      assert %Tag{id: ^tag_id, name: "Research"} = GaoNote.get_tag!(tag_id)

      assert [%Tag{id: tag_id}] = GaoNote.list_tags()
      assert tag_id == tag.id

      assert {:ok, %Tag{id: ^tag_id, color: "#0f172a", metadata: %{"scope" => "unit"}}} =
               GaoNote.update_tag(tag, %{color: "#0f172a", metadata: %{"scope" => "unit"}})

      assert %Tag{id: ^tag_id, color: "#0f172a"} = GaoNote.get_tag(tag_id)

      assert {:ok, %Tag{}} = GaoNote.delete_tag(GaoNote.get_tag!(tag_id))
      assert GaoNote.get_tag(tag_id) == nil
      assert GaoNote.list_tags() == []
    end

    test "replace_tags/3 normalizes, dedupes, and filters by tag" do
      note = note_fixture()

      assert {:ok, %Note{} = tagged_note} =
               GaoNote.replace_tags(note, ["  Elixir  ", "elixir", "MCP Tools"], actor())

      tag_slugs = tagged_note.tags |> Enum.map(& &1.slug) |> Enum.sort()
      assert tag_slugs == ["elixir", "mcp-tools"]

      assert [%Note{id: id}] = GaoNote.list_notes(tag: "elixir")
      assert id == note.id

      assert [%Tag{name: "Elixir", slug: "elixir"}, %Tag{name: "MCP Tools", slug: "mcp-tools"}] =
               GaoNote.list_tags()
    end
  end

  describe "references" do
    test "create, read, update, and delete reference lifecycle" do
      note = note_fixture()

      assert {:ok, %Reference{} = reference} =
               GaoNote.add_reference(
                 note,
                 %{
                   url: "https://example.com/reference?utm_source=feed&a=1",
                   title: "Original",
                   position: 1
                 },
                 actor()
               )

      reference_id = reference.id
      note_id = note.id

      assert [%Reference{id: ^reference_id}] = GaoNote.list_references(note)

      assert [%Reference{id: ^reference_id, note: %Note{id: ^note_id}}] =
               GaoNote.list_all_references()

      assert %Reference{id: ^reference_id, title: "Original"} =
               GaoNote.get_reference(reference_id)

      assert {:ok,
              %Reference{
                id: ^reference_id,
                title: "Updated",
                description: "Updated description",
                position: 2,
                metadata: %{"kind" => "doc"}
              }} =
               GaoNote.update_reference(
                 reference,
                 %{
                   title: "Updated",
                   description: "Updated description",
                   position: 2,
                   metadata: %{"kind" => "doc"}
                 },
                 actor()
               )

      assert %Reference{title: "Updated", position: 2} = GaoNote.get_reference(reference_id)

      assert {:ok, %Reference{id: ^reference_id}} =
               reference_id
               |> GaoNote.get_reference()
               |> GaoNote.remove_reference(actor())

      assert GaoNote.get_reference(reference_id) == nil
      assert GaoNote.list_references(note) == []
    end

    test "add_reference/3 validates http URLs and dedupes by canonical URL" do
      note = note_fixture()

      attrs = %{
        url: "https://example.com/read?utm_source=newsletter&b=1",
        title: "Example"
      }

      assert {:ok, %Reference{} = reference} = GaoNote.add_reference(note, attrs, actor())
      assert reference.url == attrs.url
      assert reference.canonical_url == "https://example.com/read?b=1"

      assert {:error, %Ecto.Changeset{}} =
               GaoNote.add_reference(
                 note,
                 %{url: "https://example.com/read?b=1&utm_medium=email"},
                 actor()
               )

      assert {:error, %Ecto.Changeset{} = changeset} =
               GaoNote.add_reference(note, %{url: "ftp://example.com/file"}, actor())

      assert %{url: [_ | _]} = errors_on(changeset)
    end
  end

  describe "assets" do
    test "create, read, update, and delete asset lifecycle" do
      note = note_fixture()
      active_file = storage_file_fixture()
      deleted_file = storage_file_fixture(%{status: "deleted"})

      assert {:ok, %Asset{} = asset} =
               GaoNote.attach_asset(note, active_file.id, %{role: "cover"}, actor())

      asset_id = asset.id

      assert %Asset{id: ^asset_id, storage_file: %StorageFile{id: file_id}} =
               GaoNote.get_asset(asset_id)

      assert file_id == active_file.id

      assert [%Asset{id: asset_id, storage_file: %StorageFile{id: file_id}}] =
               GaoNote.list_assets(note)

      assert asset_id == asset.id
      assert file_id == active_file.id
      note_id = note.id

      assert [
               %Asset{
                 id: ^asset_id,
                 note: %Note{id: ^note_id},
                 storage_file: %StorageFile{id: ^file_id}
               }
             ] =
               GaoNote.list_all_assets()

      assert {:ok,
              %Asset{
                id: ^asset_id,
                role: "inline",
                caption: "Updated caption",
                alt_text: "Updated alt",
                position: 3,
                metadata: %{"slot" => "body"}
              }} =
               GaoNote.update_asset(
                 asset,
                 %{
                   role: "inline",
                   caption: "Updated caption",
                   alt_text: "Updated alt",
                   position: 3,
                   metadata: %{"slot" => "body"}
                 },
                 actor()
               )

      assert %Asset{role: "inline", position: 3} = GaoNote.get_asset(asset_id)

      assert {:error, :storage_file_not_active} =
               GaoNote.attach_asset(note, deleted_file.id, %{}, actor())

      assert {:ok, %Asset{id: ^asset_id}} =
               asset_id
               |> GaoNote.get_asset()
               |> GaoNote.detach_asset(actor())

      assert GaoNote.get_asset(asset_id) == nil
      assert GaoNote.list_assets(note) == []
    end

    test "presenter exposes asset URLs only when storage file metadata is public" do
      private_note = note_fixture()
      private_file = storage_file_fixture(%{metadata: %{"visibility" => "public"}})

      assert {:ok, private_asset} =
               GaoNote.attach_asset(private_note, private_file.id, %{}, actor())

      private_asset = private_asset |> Repo.preload(:storage_file)
      private_map = GSMLG.GaoNote.Presenter.asset(private_asset, private_note)
      assert private_map.url == "/files/#{private_file.id}"

      hidden_file = storage_file_fixture(%{metadata: %{"visibility" => "private"}})

      assert {:ok, hidden_asset} =
               GaoNote.attach_asset(private_note, hidden_file.id, %{}, actor())

      hidden_asset = hidden_asset |> Repo.preload(:storage_file)
      hidden_map = GSMLG.GaoNote.Presenter.asset(hidden_asset, private_note)
      refute Map.has_key?(hidden_map, :url)
    end

    test "list_assets/1 excludes deleted storage files" do
      note = note_fixture()
      file = storage_file_fixture()
      assert {:ok, _asset} = GaoNote.attach_asset(note, file.id, %{}, actor())

      file
      |> StorageFile.status_changeset(%{status: "deleted"})
      |> Repo.update!()

      assert GaoNote.list_assets(note) == []
    end
  end

  defp actor(id \\ "actor-1") do
    unless Repo.get(User, id) do
      Repo.insert!(%User{
        id: id,
        username: id,
        email: "#{id}@example.test",
        password: "test"
      })
    end

    %{id: id}
  end

  defp note_fixture(attrs \\ %{}) do
    attrs =
      Map.merge(
        %{title: unique_title("Note"), description: "Description", content: "Content"},
        attrs
      )

    assert {:ok, note} = GaoNote.create_note(attrs, actor())
    note
  end

  defp storage_file_fixture(attrs \\ %{}) do
    defaults = %{
      tenant: "gao_note",
      type: "asset",
      filename: "note.txt",
      s3_key: "gao_note/asset/#{Ecto.UUID.generate()}.txt",
      content_type: "text/plain",
      size: 64,
      checksum: Ecto.UUID.generate(),
      metadata: %{},
      variants: %{},
      status: "active",
      uploaded_by: "actor-1"
    }

    %StorageFile{}
    |> StorageFile.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp unique_title(prefix) do
    "#{prefix} #{System.unique_integer([:positive])}"
  end
end
