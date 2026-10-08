defmodule GSMLG.GaoNote.Compat.LifecycleCatalogTest do
  use GSMLG.GaoNote.DataCase, async: false
  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.Compat
  alias GSMLG.GaoNote.Compat.Catalog
  alias GSMLG.GaoNote.{LabelSetting, Log, Note}

  defp save(labels) do
    {:ok, note} =
      Compat.save_note(%{title: "Title", content: "Body", labels: labels, attachments: []}, nil)

    note
  end

  test "trash sorts by deletion time descending with deterministic id ties" do
    older = save([])
    newer = save([])
    assert {:ok, _} = Compat.delete_note(older.id, 1, nil)
    assert {:ok, _} = Compat.delete_note(newer.id, 1, nil)

    Repo.update_all(from(n in Note, where: n.id == ^older.id),
      set: [
        created_at: ~U[2026-01-01 00:00:00.000000Z],
        deleted_at: ~U[2026-10-08 12:00:00.000000Z]
      ]
    )

    Repo.update_all(from(n in Note, where: n.id == ^newer.id),
      set: [
        created_at: ~U[2026-02-01 00:00:00.000000Z],
        deleted_at: ~U[2026-10-08 11:00:00.000000Z]
      ]
    )

    assert {:ok, notes} = Compat.list_deleted_notes()
    assert Enum.map(notes, & &1.id) == [older.id, newer.id]

    Repo.update_all(from(n in Note, where: n.id in ^[older.id, newer.id]),
      set: [deleted_at: ~U[2026-10-08 12:00:00.000000Z]]
    )

    assert {:ok, tied} = Compat.list_deleted_notes()
    assert Enum.map(tied, & &1.id) == Enum.sort([older.id, newer.id])
  end

  test "delete restore and purge require the current revision and expected lifecycle state" do
    note = save([{"lifecycle", "keep"}])
    assert {:error, :not_found} = Compat.restore_note(note.id, 1, nil)
    assert {:error, :not_found} = Compat.permanently_delete_note(note.id, 1, nil)
    assert {:ok, %{note: deleted, changed: true}} = Compat.delete_note(note.id, 1, nil)
    assert deleted.revision == 2
    assert Compat.get_note(note.id) == nil
    assert {:error, :not_found} = Compat.delete_note(note.id, 2, nil)

    assert {:error, {:revision_conflict, %{current_revision: 2}}} =
             Compat.restore_note(note.id, 1, nil)

    assert {:error, {:revision_conflict, %{current_revision: 2}}} =
             Compat.permanently_delete_note(note.id, 1, nil)

    assert {:ok, %{note: restored, changed: true}} = Compat.restore_note(note.id, 2, nil)
    assert restored.revision == 3
    assert Catalog.pairs(Compat.get_note(note.id)) == [{"lifecycle", "keep"}]
    assert {:ok, %{note: deleted, changed: true}} = Compat.delete_note(note.id, 3, nil)
    assert deleted.revision == 4
    assert {:ok, %{changed: true}} = Compat.permanently_delete_note(note.id, 4, nil)
    assert Repo.get(Note, note.id) == nil
  end

  test "catalog CRUD preserves case and datetime type while validating note values" do
    assert {:ok, upper} =
             Compat.define_label_key("Topic", %{description: "Upper", value_type: "text"}, nil)

    assert {:ok, lower} =
             Compat.define_label_key("topic", %{description: "Lower", value_type: "text"}, nil)

    assert upper.id != lower.id

    assert {:ok, clock} =
             Compat.define_label_key("clock", %{description: "Date", value_type: "datetime"}, nil)

    assert clock.value_type == "date-time"
    assert {:ok, edited} = Compat.update_label_key("Topic", %{description: "Edited"}, nil)
    assert edited.name == "Topic"
    assert edited.description == "Edited"
    assert Repo.get(LabelSetting, lower.id).description == "Lower"

    assert {:error, {:validation_error, _}} =
             Compat.save_note(
               %{
                 title: "Title",
                 content: "Body",
                 labels: [{"clock", "not-a-date"}],
                 attachments: []
               },
               nil
             )

    assert {:ok, _} = Compat.delete_label_key("Topic", nil)
    assert Repo.get(LabelSetting, upper.id) == nil
    assert Repo.get(LabelSetting, lower.id) != nil
  end

  test "legacy ambiguous case lookup fails without changing labels or revision" do
    assert {:ok, _} = Compat.define_label_key("Topic", "Upper", nil)
    assert {:ok, _} = Compat.define_label_key("topic", "Lower", nil)
    note = save([])

    assert {:error, {:ambiguous_label_key, "TOPIC"}} =
             GaoNote.set_labels(note, ["TOPIC=value"], nil)

    persisted = Compat.get_note(note.id)
    assert persisted.revision == 1
    assert persisted.updated_at == note.updated_at
    assert persisted.labels == []
  end

  test "stale selected label batch leaves notes catalog and audit unchanged" do
    [first, second] = [save([{"env", "prod"}]), save([{"env", "prod"}])] |> Enum.sort_by(& &1.id)

    assert {:ok, %{note: updated}} =
             Compat.patch_note(second.id, 1, %{title: "Concurrent edit"}, nil)

    snapshots = Map.new([first.id, second.id], fn id -> {id, snapshot(Compat.get_note(id))} end)
    log_count = Repo.aggregate(Log, :count)

    assert {:error, {:revision_conflict, %{note_id: id, current_revision: 2}}} =
             Compat.batch_update_note_labels(
               %{
                 notes: [
                   %{id: first.id, expected_revision: 1},
                   %{id: second.id, expected_revision: 1}
                 ],
                 action: %{type: "add", key: "should-not-exist", value: "value"}
               },
               nil
             )

    assert id == updated.id

    assert Map.new([first.id, second.id], fn id -> {id, snapshot(Compat.get_note(id))} end) ==
             snapshots

    assert Repo.get_by(LabelSetting, name: "should-not-exist") == nil
    assert Repo.aggregate(Log, :count) == log_count
  end

  test "invalid destination values leave the selected notes and audit unchanged" do
    assert {:ok, _} = Compat.define_label_key("amount", %{value_type: "number"}, nil)
    [first, second] = [save([{"env", "prod"}]), save([{"env", "prod"}])] |> Enum.sort_by(& &1.id)
    snapshots = Map.new([first.id, second.id], fn id -> {id, snapshot(Compat.get_note(id))} end)
    log_count = Repo.aggregate(Log, :count)

    assert {:error, {:validation_error, _}} =
             Compat.batch_update_note_labels(
               %{
                 notes: [
                   %{id: first.id, expected_revision: 1},
                   %{id: second.id, expected_revision: 1}
                 ],
                 action: %{type: "add", key: "amount", value: "not-a-number"}
               },
               nil
             )

    assert Map.new([first.id, second.id], fn id -> {id, snapshot(Compat.get_note(id))} end) ==
             snapshots

    assert Repo.aggregate(Log, :count) == log_count
  end

  test "selected label actions count actual changes and preserve no-op timestamps" do
    first = save([{"env", "prod"}])
    second = save([])
    targets = [%{id: first.id, expected_revision: 1}, %{id: second.id, expected_revision: 1}]

    assert {:ok, %{requested: 2, updated: 1, unchanged: 1}} =
             Compat.batch_update_note_labels(
               %{notes: targets, action: %{type: "add", key: "env", value: "stage"}},
               nil
             )

    assert snapshot(Compat.get_note(first.id)) == snapshot(first)
    assert Compat.get_note(second.id).revision == 2

    assert {:ok, %{requested: 1, updated: 1, unchanged: 0}} =
             Compat.batch_update_note_labels(
               %{
                 notes: [%{id: second.id, expected_revision: 2}],
                 action: %{type: "update", from_key: "env", key: "team", value: "core"}
               },
               nil
             )

    assert Catalog.pairs(Compat.get_note(second.id)) == [{"team", "core"}]

    assert {:ok, %{requested: 1, updated: 1, unchanged: 0}} =
             Compat.batch_update_note_labels(
               %{
                 notes: [%{id: second.id, expected_revision: 3}],
                 action: %{type: "remove", key: "team"}
               },
               nil
             )

    assert Compat.get_note(second.id).revision == 4
  end

  defp snapshot(note),
    do: {note.title, note.content, note.revision, note.updated_at, Catalog.pairs(note)}
end
