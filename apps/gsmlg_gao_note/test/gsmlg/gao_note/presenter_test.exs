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
             "metadata" => %{"language" => "en"},
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

  test "only already-present public storage content is exposed" do
    public_file = storage_file_fixture("public") |> Map.put(:content, "public content")
    private_file = storage_file_fixture("private") |> Map.put(:content, "private content")

    public_storage =
      public_file
      |> attachment_fixture()
      |> Presenter.attachment()
      |> Map.fetch!("storage_file")

    private_storage =
      private_file
      |> attachment_fixture()
      |> Presenter.attachment()
      |> Map.fetch!("storage_file")

    assert public_storage["content"] == "public content"
    refute Map.has_key?(private_storage, "content")
  end

  defp attachment_fixture(storage_file) do
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
      metadata: %{"language" => "en"}
    }
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
