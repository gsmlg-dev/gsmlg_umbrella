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

  describe "attachment context" do
    test "exports only the final attachment APIs" do
      for {name, arity} <- [
            list_attachments: 1,
            list_all_attachments: 1,
            get_attachment: 1,
            change_attachment: 2,
            attach_existing_file: 4,
            upload_attachment: 4,
            update_attachment: 3,
            detach_attachment: 2
          ] do
        assert function_exported?(GaoNote, name, arity)
      end

      for {name, arity} <- [
            list_references: 1,
            list_all_references: 1,
            get_reference: 1,
            change_reference: 2,
            add_reference: 3,
            update_reference: 3,
            remove_reference: 2,
            list_assets: 1,
            list_all_assets: 1,
            get_asset: 1,
            change_asset: 2,
            attach_asset: 4,
            upload_asset: 4,
            update_asset: 3,
            detach_asset: 2
          ] do
        refute function_exported?(GaoNote, name, arity)
      end
    end

    test "lists ordered active attachments for active notes with associations preloaded" do
      note = note_fixture()
      first_file = storage_file_fixture(%{filename: "first.txt"})
      second_file = storage_file_fixture(%{filename: "second.txt"})
      third_file = storage_file_fixture(%{filename: "third.txt"})
      inactive_file = storage_file_fixture(%{filename: "inactive.txt", status: "deleted"})

      first = attachment_fixture(note, first_file, %{position: 0, path: "first.txt"})
      second = attachment_fixture(note, second_file, %{position: 0, path: "second.txt"})
      third = attachment_fixture(note, third_file, %{position: 1, path: "third.txt"})
      inactive = attachment_fixture(note, inactive_file, %{position: 0, path: "inactive.txt"})

      deleted_note = note_fixture()
      deleted_file = storage_file_fixture(%{filename: "deleted-note.txt"})
      deleted_attachment = attachment_fixture(deleted_note, deleted_file)
      assert {:ok, _deleted_note} = GaoNote.delete_note(deleted_note, actor())

      assert [
               %Attachment{id: first_id, storage_file: %StorageFile{id: first_file_id}},
               %Attachment{id: second_id, storage_file: %StorageFile{id: second_file_id}},
               %Attachment{id: third_id, storage_file: %StorageFile{id: third_file_id}}
             ] = GaoNote.list_attachments(note.id)

      assert {first_id, second_id, third_id} == {first.id, second.id, third.id}
      assert {first_file_id, second_file_id, third_file_id} ==
               {first_file.id, second_file.id, third_file.id}

      assert GaoNote.list_attachments(deleted_note.id) == []
      assert GaoNote.list_attachments("not-a-uuid") == []

      all = GaoNote.list_all_attachments(%{limit: "200", offset: "0"})
      assert Enum.sort(Enum.map(all, & &1.id)) == Enum.sort([first.id, second.id, third.id])
      assert Enum.all?(all, &Ecto.assoc_loaded?(&1.storage_file))
      assert Enum.all?(all, &Ecto.assoc_loaded?(&1.note))

      assert %Attachment{id: id, storage_file: %StorageFile{}} = GaoNote.get_attachment(second.id)
      assert id == second.id
      assert GaoNote.get_attachment("not-a-uuid") == nil
      assert GaoNote.get_attachment(inactive.id) == nil
      assert GaoNote.get_attachment(deleted_attachment.id) == nil
    end

    test "normal note results preload labels and attachments without false empty lists" do
      note = note_fixture()
      file = storage_file_fixture()
      attachment = attachment_fixture(note, file)

      assert Ecto.assoc_loaded?(note.labels)
      assert Ecto.assoc_loaded?(note.attachments)

      assert %Note{attachments: [%Attachment{id: attachment_id}]} = GaoNote.get_note(note.id)
      assert attachment_id == attachment.id

      assert %Note{attachments: [%Attachment{id: public_attachment_id}]} =
               GaoNote.get_public_note(note.id)

      assert public_attachment_id == attachment.id

      listed_note = Enum.find(GaoNote.list_notes(), &(&1.id == note.id))
      assert %Note{attachments: [%Attachment{id: listed_attachment_id}]} = listed_note
      assert listed_attachment_id == attachment.id
      assert Ecto.assoc_loaded?(listed_note.labels)

      assert {:ok, %Note{attachments: [%Attachment{id: updated_attachment_id}]}} =
               GaoNote.update_note(note, %{description: "Updated"}, actor())

      assert updated_attachment_id == attachment.id
    end

    test "attaches active existing files and rejects invalid scopes" do
      note = note_fixture()
      file = storage_file_fixture(%{filename: "temporary-upload-name.txt"})

      assert {:ok,
              %Attachment{
                note_id: note_id,
                storage_file_id: storage_file_id,
                path: nil,
                role: "inline",
                storage_file: %StorageFile{id: preloaded_file_id}
              } = attachment} =
               GaoNote.attach_existing_file(
                 note.id,
                 file.id,
                 %{role: "inline", caption: "Diagram"},
                 actor: actor("attachment-owner")
               )

      assert note_id == note.id
      assert storage_file_id == file.id
      assert preloaded_file_id == file.id

      changeset = GaoNote.change_attachment(attachment, %{caption: "Updated caption"})
      assert Ecto.Changeset.get_change(changeset, :caption) == "Updated caption"

      assert %Log{entity_type: "attachment", actor_id: "attachment-owner"} =
               GaoNote.list_logs(entity_type: "attachment") |> hd()

      inactive_file = storage_file_fixture(%{status: "deleted"})
      assert {:error, :storage_file_not_active} =
               GaoNote.attach_existing_file(note.id, inactive_file.id, %{}, [])

      assert {:error, :storage_file_not_active} =
               GaoNote.attach_existing_file(note.id, "not-a-uuid", %{}, [])

      assert {:error, :not_found} =
               GaoNote.attach_existing_file(Ecto.UUID.generate(), file.id, %{}, [])

      deleted_note = note_fixture()
      assert {:ok, _deleted_note} = GaoNote.delete_note(deleted_note, actor())
      assert {:error, :not_found} =
               GaoNote.attach_existing_file(deleted_note.id, file.id, %{}, [])
    end

    test "uploads through the attachment storage type after validating the note" do
      original = Application.get_env(:gsmlg_storage, :allowed_types)

      on_exit(fn ->
        if original,
          do: Application.put_env(:gsmlg_storage, :allowed_types, original),
          else: Application.delete_env(:gsmlg_storage, :allowed_types)
      end)

      Application.put_env(:gsmlg_storage, :allowed_types, %{"attachment" => ~w(image/png)})

      note = note_fixture()

      assert {:error, {:content_type_not_allowed, _content_type, "attachment"}} =
               GaoNote.upload_attachment(
                 note.id,
                 {"temporary-upload-name.txt", "hello world content"},
                 %{path: "./client-name.txt"},
                 actor: actor("uploader")
               )

      assert {:ok, _deleted_note} = GaoNote.delete_note(note, actor())

      assert {:error, :not_found} =
               GaoNote.upload_attachment(
                 note.id,
                 {"temporary-upload-name.txt", "hello world content"},
                 %{},
                 []
               )
    end

    test "updates and detaches only within an active note without deleting storage" do
      note = note_fixture()
      other_note = note_fixture()
      file = storage_file_fixture()
      attachment = attachment_fixture(note, file)

      assert {:error, :not_found} =
               GaoNote.update_attachment(other_note.id, attachment.id, %{caption: "Wrong note"})

      assert {:error, :not_found} =
               GaoNote.update_attachment(note.id, "not-a-uuid", %{caption: "Invalid"})

      assert {:ok, %Attachment{caption: "Updated", position: 4, storage_file: %StorageFile{}}} =
               GaoNote.update_attachment(note.id, attachment.id, %{caption: "Updated", position: 4})

      assert {:error, :not_found} = GaoNote.detach_attachment(other_note.id, attachment.id)
      assert {:error, :not_found} = GaoNote.detach_attachment(note.id, "not-a-uuid")
      assert {:ok, %Attachment{id: detached_id}} = GaoNote.detach_attachment(note.id, attachment.id)
      assert detached_id == attachment.id
      assert Repo.get(Attachment, attachment.id) == nil
      assert %StorageFile{status: "active"} = Repo.get(StorageFile, file.id)
      assert {:error, :not_found} = GaoNote.detach_attachment(note.id, attachment.id)

      deleted_note = note_fixture()
      deleted_file = storage_file_fixture()
      deleted_attachment = attachment_fixture(deleted_note, deleted_file)
      assert {:ok, _deleted_note} = GaoNote.delete_note(deleted_note, actor())

      assert {:error, :not_found} =
               GaoNote.update_attachment(deleted_note.id, deleted_attachment.id, %{caption: "Hidden"})

      assert {:error, :not_found} =
               GaoNote.detach_attachment(deleted_note.id, deleted_attachment.id)
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

  defp attachment_fixture(note, file, attrs \\ %{}) do
    attrs = Map.merge(%{note_id: note.id, storage_file_id: file.id}, attrs)

    %Attachment{}
    |> Attachment.changeset(attrs)
    |> Repo.insert!()
  end

  defp unique_title(prefix) do
    "#{prefix} #{System.unique_integer([:positive])}"
  end
end
