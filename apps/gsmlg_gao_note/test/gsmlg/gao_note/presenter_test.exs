defmodule GSMLG.GaoNote.PresenterTest do
  use ExUnit.Case, async: true

  alias GSMLG.GaoNote.{Attachment, Label, LabelSetting, Note, Presenter}
  alias GSMLG.Storage.StorageFile

  @inserted_at ~U[2026-07-15 01:02:03.000000Z]
  @updated_at ~U[2026-07-15 04:05:06.000000Z]

  test "note/1 exposes only the final public note keys" do
    presented =
      Presenter.note(%Note{
        id: "note-1",
        title: "Presenter hard break",
        description: "Final note shape",
        content: "# Note",
        labels: [],
        attachments: [],
        created_at: @inserted_at,
        updated_at: @updated_at,
        deleted_at: @updated_at
      })

    assert presented == %{
             "id" => "note-1",
             "title" => "Presenter hard break",
             "description" => "Final note shape",
             "content" => "# Note",
             "labels" => [],
             "attachments" => [],
             "created_at" => "2026-07-15T01:02:03.000000Z",
             "updated_at" => "2026-07-15T04:05:06.000000Z"
           }

    for legacy_key <- ~w(tags references assets chunks sha256 deleted_at) do
      refute Map.has_key?(presented, legacy_key)
    end
  end

  test "legacy reference and asset presenter functions are removed" do
    refute function_exported?(Presenter, :reference, 1)
    refute function_exported?(Presenter, :asset, 2)
    refute function_exported?(Presenter, :asset_json, 2)
  end

  test "label/1 presents the final key and value contract" do
    presented =
      Presenter.label(%Label{
        label_setting: %LabelSetting{name: "topic", value_type: "text"},
        value: "ecto"
      })

    assert %{"key" => "topic", "value" => "ecto"} = presented
    refute Map.has_key?(presented, "name")
  end

  test "attachment/1 exposes attachment and client-safe storage-file metadata" do
    attachment =
      attachment_fixture(storage_file_fixture("public"))

    assert Presenter.attachment(attachment) == %{
             "id" => "attachment-1",
             "role" => "source",
             "description" => "Source document",
             "path" => "./source.txt",
             "caption" => "Original source",
             "alt_text" => "A source document",
             "position" => 2,
             "visibility" => "public",
             "metadata" => %{"language" => "en", "visibility" => "public"},
             "path" => "./source.txt",
             "storage_file" => %{
               "id" => "storage-file-1",
               "filename" => "source.txt",
               "content_type" => "text/plain",
               "size" => 42,
               "visibility" => "public",
               "inserted_at" => "2026-07-15T01:02:03.000000Z",
               "updated_at" => "2026-07-15T04:05:06.000000Z"
             }
           }
  end

  test "unloaded associations serialize without raising" do
    presented_note = Presenter.note(%Note{})

    assert presented_note["labels"] == []
    assert presented_note["attachments"] == []
    assert Presenter.attachment(%Attachment{})["storage_file"] == nil
  end

  test "public storage with a private attachment remains private without content or paths" do
    attachment =
      storage_file_fixture("public")
      |> Map.put(:content, "private attachment content")
      |> attachment_fixture("private")

    attachment = %{
      attachment
      | metadata:
          Map.merge(attachment.metadata, %{
            "content_url" => "https://internal.example/content",
            "s3_key" => "internal/object",
            "internal_path" => "/internal/path"
          })
    }

    attachment
    |> Presenter.attachment()
    |> assert_private_attachment()
  end

  test "private storage is a floor even when the attachment setting is public" do
    storage_file_fixture("private")
    |> Map.put(:content, "private storage content")
    |> attachment_fixture("public")
    |> Presenter.attachment()
    |> assert_private_attachment()
  end

  test "public storage and public attachment expose already-hydrated content" do
    presented =
      storage_file_fixture("public")
      |> Map.put(:content, "public content")
      |> attachment_fixture("public")
      |> Presenter.attachment()

    assert presented["visibility"] == "public"
    assert presented["path"] == "./source.txt"
    assert presented["storage_file"]["visibility"] == "public"
    assert presented["storage_file"]["content"] == "public content"
  end

  test "missing attachment visibility falls back to storage visibility" do
    public =
      storage_file_fixture("public")
      |> Map.put(:content, "public fallback")
      |> attachment_fixture()
      |> Presenter.attachment()

    private =
      storage_file_fixture("private")
      |> Map.put(:content, "private fallback")
      |> attachment_fixture()
      |> Presenter.attachment()

    assert public["visibility"] == "public"
    assert public["storage_file"]["content"] == "public fallback"
    assert private["visibility"] == "private"
    refute Map.has_key?(private, "path")
    refute Map.has_key?(private["storage_file"], "content")
  end

  defp attachment_fixture(storage_file, visibility \\ :missing) do
    metadata =
      case visibility do
        :missing -> %{"language" => "en"}
        visibility -> %{"language" => "en", "visibility" => visibility}
      end

    %Attachment{
      id: "attachment-1",
      note_id: "note-1",
      storage_file_id: "storage-file-1",
      storage_file: storage_file,
      role: "source",
      description: "Source document",
      path: "./source.txt",
      caption: "Original source",
      alt_text: "A source document",
      position: 2,
      metadata: metadata
    }
  end

  defp assert_private_attachment(presented) do
    assert presented["visibility"] == "private"
    assert presented["metadata"]["visibility"] == "private"
    assert presented["storage_file"]["visibility"] == "private"

    for key <- ~w(path content content_url s3_key internal_path) do
      refute Map.has_key?(presented, key)
      refute Map.has_key?(presented["metadata"], key)
      refute Map.has_key?(presented["storage_file"], key)
    end

    presented
  end

  defp storage_file_fixture(visibility) do
    %StorageFile{
      id: "storage-file-1",
      filename: "source.txt",
      s3_key: "gao_note/attachment/internal-object-key",
      content_type: "text/plain",
      size: 42,
      metadata: %{"visibility" => visibility},
      status: "active",
      inserted_at: @inserted_at,
      updated_at: @updated_at
    }
  end
end
