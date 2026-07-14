defmodule GSMLG.GaoNoteTest do
  use GSMLG.GaoNote.DataCase, async: false

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

  describe "label_settings" do
    test "create, read, update, and delete label_setting lifecycle" do
      assert {:ok, %LabelSetting{name: "Research"} = label_setting} =
               GaoNote.create_label_setting(%{name: "  Research  ", color: "#1f6feb"})

      label_setting_id = label_setting.id
      refute Map.has_key?(label_setting, :slug)

      assert %LabelSetting{id: ^label_setting_id, name: "Research"} = GaoNote.get_label_setting(label_setting_id)
      assert %LabelSetting{id: ^label_setting_id, name: "Research"} = GaoNote.get_label_setting!(label_setting_id)

      assert [%LabelSetting{id: label_setting_id}] = GaoNote.list_label_settings()
      assert label_setting_id == label_setting.id

      assert {:ok, %LabelSetting{id: ^label_setting_id, color: "#0f172a", metadata: %{"scope" => "unit"}}} =
               GaoNote.update_label_setting(label_setting, %{color: "#0f172a", metadata: %{"scope" => "unit"}})

      assert %LabelSetting{id: ^label_setting_id, color: "#0f172a"} = GaoNote.get_label_setting(label_setting_id)

      assert {:ok, %LabelSetting{}} = GaoNote.delete_label_setting(GaoNote.get_label_setting!(label_setting_id))
      assert GaoNote.get_label_setting(label_setting_id) == nil
      assert GaoNote.list_label_settings() == []
    end

    test "replace_label_settings/3 normalizes, dedupes, and filters by label_setting" do
      note = note_fixture()

      assert {:ok, %Note{} = tagged_note} =
               GaoNote.replace_label_settings(note, ["  Elixir  ", "elixir", "MCP Tools"], actor())

      tag_names = tagged_note.labels |> Enum.map(& &1.name) |> Enum.sort()
      assert tag_names == ["Elixir", "MCP Tools"]

      assert [%Note{id: id}] = GaoNote.list_notes(label_setting: "elixir")
      assert id == note.id

      assert [%LabelSetting{name: "Elixir"}, %LabelSetting{name: "MCP Tools"}] = GaoNote.list_label_settings()
    end
  end

  describe "attachment schema" do
    test "uses the attachment table and exposes only final subordinate associations" do
      assert Attachment.__schema__(:source) == "gao_note_attachments"
      assert Attachment.__schema__(:type, :id) == :binary_id
      assert Enum.sort(Note.__schema__(:associations)) == [:attachments, :labels]
      assert Note.__schema__(:association, :attachments).related == Attachment
      assert Note.__schema__(:association, :labels).related == Label
    end

    test "keeps attachment fields and defaults description" do
      assert Enum.sort(Attachment.__schema__(:fields)) ==
               Enum.sort([
                 :alt_text,
                 :caption,
                 :description,
                 :id,
                 :inserted_at,
                 :metadata,
                 :note_id,
                 :path,
                 :position,
                 :role,
                 :storage_file_id,
                 :updated_at
               ])

      changeset =
        %Attachment{description: nil}
        |> Attachment.changeset(attachment_attrs())

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :description) == ""
      assert Ecto.Changeset.get_field(changeset, :role) == "attachment"
      assert Ecto.Changeset.get_field(changeset, :position) == 0
      assert Ecto.Changeset.get_field(changeset, :metadata) == %{}
    end

    test "normalizes blank and relative attachment paths" do
      for {path, expected} <- [
            {"  ", nil},
            {"./data.txt", "./data.txt"},
            {"nested/data.txt", "./nested/data.txt"}
          ] do
        changeset = Attachment.changeset(%Attachment{}, attachment_attrs(%{path: path}))

        assert changeset.valid?
        assert Ecto.Changeset.get_field(changeset, :path) == expected
      end
    end

    test "rejects absolute paths, parent traversal, URLs, and invalid normalized paths" do
      for path <- [
            "/etc/passwd",
            "C:\\Windows\\system.ini",
            "\\\\server\\share\\file",
            "\\rooted\\file",
            "../secret.txt",
            "./nested/../secret.txt",
            "https://example.com/data.txt"
          ] do
        changeset = Attachment.changeset(%Attachment{}, attachment_attrs(%{path: path}))

        refute changeset.valid?
        assert %{path: [_ | _]} = errors_on(changeset)
      end
    end

    test "uses final attachment index names and enforces both unique constraints" do
      note =
        %Note{}
        |> Note.create_changeset(%{title: unique_title("Attachment"), content: "Content"})
        |> Repo.insert!()

      first_file = storage_file_fixture()
      second_file = storage_file_fixture()

      changeset =
        Attachment.changeset(
          %Attachment{},
          attachment_attrs(%{
            note_id: note.id,
            storage_file_id: first_file.id,
            path: "data.txt"
          })
        )

      assert Enum.map(changeset.constraints, & &1.constraint) == [
               "gao_note_attachments_note_id_storage_file_id_index",
               "gao_note_attachments_note_id_path_index"
             ]

      assert {:ok, %Attachment{path: "./data.txt"}} = Repo.insert(changeset)

      assert {:error, duplicate_file_changeset} =
               %Attachment{}
               |> Attachment.changeset(
                 attachment_attrs(%{
                   note_id: note.id,
                   storage_file_id: first_file.id,
                   path: "copy.txt"
                 })
               )
               |> Repo.insert()

      assert %{storage_file_id: [_ | _]} = errors_on(duplicate_file_changeset)

      assert {:error, duplicate_path_changeset} =
               %Attachment{}
               |> Attachment.changeset(
                 attachment_attrs(%{
                   note_id: note.id,
                   storage_file_id: second_file.id,
                   path: "./data.txt"
                 })
               )
               |> Repo.insert()

      assert %{path: [_ | _]} = errors_on(duplicate_path_changeset)
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
      type: "attachment",
      filename: "note.txt",
      s3_key: "gao_note/attachment/#{Ecto.UUID.generate()}.txt",
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

  defp attachment_attrs(attrs \\ %{}) do
    Map.merge(
      %{
        note_id: Ecto.UUID.generate(),
        storage_file_id: Ecto.UUID.generate()
      },
      attrs
    )
  end

  defp unique_title(prefix) do
    "#{prefix} #{System.unique_integer([:positive])}"
  end
end
