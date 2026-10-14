defmodule GSMLG.GaoNote.Sync.SnapshotTest do
  use GSMLG.GaoNote.DataCase, async: false

  setup do
    GSMLG.Storage.TestCatalogClient.setup!()
    :ok
  end

  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{Attachment, Compat, Note}
  alias GSMLG.GaoNote.Sync.Snapshot
  alias GSMLG.Storage.StorageFile

  test "captures exact catalog metadata and trash timestamps in seconds" do
    assert {:ok, _} =
             Compat.define_label_key("Project", %{description: "Exact", value_type: "text"})

    assert {:ok, note} =
             Compat.save_note(
               %{title: "Test", content: "Body", labels: [%{key: "Project", value: "bear_note"}]},
               nil
             )

    assert {:ok, deleted} = GaoNote.delete_note(note, nil)
    assert {:ok, %{snapshot: snapshot, objects: %{}}} = Snapshot.build(note.id)

    assert snapshot["labels"] == [
             %{
               "key" => "Project",
               "value" => "bear_note",
               "description" => "Exact",
               "value_type" => "text"
             }
           ]

    assert snapshot["created_at"] == DateTime.to_unix(note.created_at)
    assert snapshot["updated_at"] == DateTime.to_unix(deleted.updated_at)
    assert snapshot["deleted_at"] == DateTime.to_unix(deleted.deleted_at)
  end

  test "exports native date-time labels using the v1 datetime spelling" do
    assert {:ok, _} = GaoNote.create_label_setting(%{name: "when", value_type: "date-time"})

    assert {:ok, note} =
             GaoNote.create_note(
               %{title: "Date", content: "Body", labels: ["when=2026-10-11T08:00:00Z"]},
               nil
             )

    assert {:ok, %{snapshot: %{"labels" => [label]}}} = Snapshot.build(note.id)
    assert label["value_type"] == "datetime"
    assert label["value"] == "2026-10-11T08:00:00Z"
  end

  test "exports public IDs and normalized paths without local storage identities" do
    assert {:ok, note} = GaoNote.create_note(%{title: "Test", content: "Body"}, nil)
    checksum = :crypto.hash(:sha256, "data") |> Base.encode16(case: :lower)
    file = insert_file(checksum, 4)

    Repo.insert!(
      Attachment.changeset(%Attachment{}, %{
        id: "internal",
        api_id: "event",
        note_id: note.id,
        storage_file_id: file.id,
        path: "./docs//file.txt",
        mime: "text/plain"
      })
    )

    assert {:ok, %{snapshot: snapshot, objects: objects}} = Snapshot.build(note.id)

    assert snapshot["attachments"] == [
             %{
               "id" => "event",
               "path" => "docs/file.txt",
               "mime" => "text/plain",
               "description" => "",
               "size_bytes" => 4,
               "checksum_sha256" => checksum
             }
           ]

    assert objects == %{"event" => file.id}
    refute Jason.encode!(snapshot) =~ file.id
    refute Jason.encode!(snapshot) =~ file.s3_key
  end

  test "stored metadata lets oversized current attachments remain editable" do
    assert {:ok, note} = GaoNote.create_note(%{title: "Test", content: "Body"}, nil)
    file = insert_file(String.duplicate("a", 64), 536_870_913)

    Repo.insert!(
      Attachment.changeset(%Attachment{}, %{
        id: "large",
        note_id: note.id,
        storage_file_id: file.id,
        path: "large.txt",
        mime: "text/plain"
      })
    )

    assert {:ok, %{snapshot: %{"attachments" => [%{"size_bytes" => 536_870_913}]}}} =
             Snapshot.build(note.id)

    assert {:error, :object_too_large} = Snapshot.read_object(file.id)
  end

  test "missing note and storage object are explicit errors" do
    assert {:error, :not_found} = Snapshot.build(Ecto.UUID.generate())
    assert {:error, :object_unavailable} = Snapshot.read_object(Ecto.UUID.generate())
    refute Repo.exists?(Note)
  end

  defp insert_file(checksum, size) do
    %StorageFile{}
    |> StorageFile.changeset(%{
      tenant: "gao_note",
      type: "gao_note_attachment",
      filename: "file.txt",
      s3_key: "sync/#{Ecto.UUID.generate()}",
      content_type: "text/plain",
      size: size,
      checksum: checksum,
      variants: %{}
    })
    |> GSMLG.Storage.TestCatalogClient.insert_file!()
  end
end
