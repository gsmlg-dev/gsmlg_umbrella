defmodule GSMLG.GaoNoteRevisionTest do
  use GSMLG.GaoNote.DataCase, async: false

  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.Compat

  test "legacy writers advance shared revisions only when state changes" do
    assert {:ok, note} = GaoNote.create_note(%{title: "Title", content: "Body"}, nil)
    assert Map.get(note, :revision) == 1
    assert {:ok, unchanged} = GaoNote.update_note_fields(note, %{title: "Title"}, nil)
    assert unchanged.revision == 1
    assert unchanged.updated_at == note.updated_at
    assert {:ok, changed} = GaoNote.update_note_fields(note, %{title: "Changed"}, nil)
    assert changed.revision == 2
    assert {:ok, labeled} = GaoNote.set_labels(changed, ["env=prod"], nil)
    assert labeled.revision == 3
    assert {:ok, same} = GaoNote.set_labels(labeled, ["env=prod"], nil)
    assert same.revision == 3
    assert same.updated_at == labeled.updated_at
    assert {:ok, deleted} = GaoNote.delete_note(same, nil)
    assert deleted.revision == 4
    assert {:ok, restored} = GaoNote.restore_note(deleted, nil)
    assert restored.revision == 5
  end

  test "revision guarded patches preserve omitted fields and reject stale legacy snapshots" do
    assert {:ok, note} =
             Compat.save_note(
               %{title: "Title", content: "Body", labels: [{"env", "prod"}], attachments: []},
               nil
             )

    assert {:ok, %{note: unchanged, changed: false}} =
             Compat.patch_note(note.id, 1, %{title: "Title"}, nil)

    assert unchanged.updated_at == note.updated_at

    assert {:ok, %{note: changed, changed: true}} =
             Compat.patch_note(note.id, 1, %{title: "Changed"}, nil)

    assert changed.revision == 2
    assert changed.content == "Body"

    assert {:error, {:revision_conflict, %{current_revision: 2}}} =
             Compat.patch_note(note.id, 1, %{title: "Stale"}, nil)

    assert {:ok, legacy} = GaoNote.update_note_fields(changed, %{content: "Legacy"}, nil)
    assert legacy.revision == 3

    assert {:error, {:revision_conflict, %{current_revision: 3}}} =
             Compat.delete_note(note.id, 2, nil)
  end
end
