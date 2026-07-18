defmodule GSMLG.GaoNote.PresenterTest do
  use ExUnit.Case, async: true

  alias GSMLG.GaoNote.{Attachment, Label, LabelSetting, Note, Presenter}

  @inserted_at ~U[2026-07-15 01:02:03.000000Z]
  @updated_at ~U[2026-07-15 04:05:06.000000Z]

  test "note/1 exposes only the public note and attachment aggregate" do
    attachments = [
      attachment_fixture("attachment-z", "./zeta/file.txt", "text/plain", nil),
      attachment_fixture(
        "attachment-b",
        "./docs/資料 #1?%.txt",
        "text/plain",
        "Unicode source"
      ),
      attachment_fixture("attachment-a", "./docs/資料 #1?%.txt", "text/plain", "First")
    ]

    presented =
      Presenter.note(%Note{
        id: "note-1",
        title: "Presenter hard break",
        content: "# Note",
        labels: [],
        attachments: attachments,
        created_at: @inserted_at,
        updated_at: @updated_at,
        deleted_at: @updated_at
      })

    assert presented == %{
             "id" => "note-1",
             "title" => "Presenter hard break",
             "content" => "# Note",
             "labels" => [],
             "attachments" => [
               %{
                 "id" => "attachment-a",
                 "path" => "./docs/資料 #1?%.txt",
                 "mime" => "text/plain",
                 "description" => "First",
                 "content_url" =>
                   "/api/gao_notes/note-1/attachments/docs/%E8%B3%87%E6%96%99%20%231%3F%25.txt"
               },
               %{
                 "id" => "attachment-b",
                 "path" => "./docs/資料 #1?%.txt",
                 "mime" => "text/plain",
                 "description" => "Unicode source",
                 "content_url" =>
                   "/api/gao_notes/note-1/attachments/docs/%E8%B3%87%E6%96%99%20%231%3F%25.txt"
               },
               %{
                 "id" => "attachment-z",
                 "path" => "./zeta/file.txt",
                 "mime" => "text/plain",
                 "description" => "",
                 "content_url" =>
                   "/api/gao_notes/note-1/attachments/zeta/file.txt"
               }
             ],
             "created_at" => "2026-07-15T01:02:03.000000Z",
             "updated_at" => "2026-07-15T04:05:06.000000Z"
           }

    for legacy_key <- ~w(description creator tags references assets chunks sha256 deleted_at) do
      refute Map.has_key?(presented, legacy_key)
    end

    for attachment <- presented["attachments"] do
      assert Map.keys(attachment) |> Enum.sort() ==
               ~w(content_url description id mime path)

      for leaked_key <-
            ~w(storage_file_id storage_file content content_base64 visibility role caption alt_text position metadata creator tags references assets chunks) do
        refute Map.has_key?(attachment, leaked_key)
      end
    end
  end

  test "legacy reference and asset presenter functions are removed" do
    functions = Presenter.__info__(:functions)

    refute {:reference, 1} in functions
    refute {:asset, 2} in functions
    refute {:asset_json, 2} in functions
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

  test "unloaded associations serialize without raising" do
    presented_note = Presenter.note(%Note{})

    assert presented_note["labels"] == []
    assert presented_note["attachments"] == []
  end

  defp attachment_fixture(id, path, mime, description) do
    %Attachment{
      id: id,
      note_id: "note-1",
      path: path,
      mime: mime,
      description: description
    }
    |> Map.merge(%{
      storage_file_id: "internal-storage-#{id}",
      storage_file: %{id: "internal-storage-#{id}", content: "raw bytes"},
      content: "raw bytes",
      visibility: "private",
      role: "source",
      caption: "legacy caption",
      alt_text: "legacy alt text",
      position: 99,
      metadata: %{"secret" => true}
    })
  end
end
