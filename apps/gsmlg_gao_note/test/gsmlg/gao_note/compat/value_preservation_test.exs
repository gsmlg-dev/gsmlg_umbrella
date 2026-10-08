defmodule GSMLG.GaoNote.Compat.ValuePreservationTest do
  use GSMLG.GaoNote.DataCase, async: false
  alias GSMLG.GaoNote.Compat
  alias GSMLG.GaoNote.Compat.Catalog

  test "catalog descriptions preserve whitespace on define and update" do
    assert {:ok, setting} = Compat.define_label_key("raw-description", "  ", nil)
    assert setting.description == "  "
    assert {:ok, updated} = Compat.update_label_key("raw-description", " \t ", nil)
    assert updated.description == " \t "
  end

  test "exact text labels keep all whitespace and invalid typed no-op actions are rejected" do
    {:ok, note} =
      Compat.save_note(%{title: "Whitespace", content: "Body", labels: [{"raw", "  "}]}, nil)

    assert Catalog.pairs(note) == [{"raw", "  "}]

    assert {:ok, %{changed: false}} =
             Compat.patch_note(note.id, 1, %{labels: [["raw", "  "]]}, nil)

    {:ok, _} = Compat.define_label_key("amount", %{description: "", value_type: "number"}, nil)

    {:ok, amount} =
      Compat.save_note(%{title: "Amount", content: "Body", labels: [["amount", "1"]]}, nil)

    assert {:error, {:validation_error, _}} =
             Compat.batch_update_note_labels(
               %{
                 notes: [%{id: amount.id, expected_revision: 1}],
                 action: %{type: "add", key: "amount", value: "bad"}
               },
               nil
             )

    assert Compat.get_note(amount.id).revision == 1
  end

  test "compat typed labels use reference version time datetime rules" do
    for {key, type, valid, invalid} <- [
          {"version", "version", "1.2.3.4.5", "1.2-alpha"},
          {"time", "time", "09:30", "24:00"},
          {"datetime", "datetime", "2026-10-08 09:30", "2026-10-08T09:30:00Z"}
        ] do
      {:ok, _} = Compat.define_label_key(key, %{description: "", value_type: type}, nil)

      assert {:ok, _} =
               Compat.save_note(%{title: key, content: "Body", labels: [[key, valid]]}, nil)

      assert {:error, {:validation_error, _}} =
               Compat.save_note(%{title: key, content: "Body", labels: [[key, invalid]]}, nil)
    end
  end

  test "lifecycle preserves update time and bulk updates advance wire seconds" do
    {:ok, note} =
      Compat.save_note(%{title: "Time", content: "Body", labels: [["env", "prod"]]}, nil)

    assert {:ok, %{updated: 1}} =
             Compat.bulk_update_note_labels(%{selector: "env=prod", set: [["team", "core"]]}, nil)

    updated = Compat.get_note(note.id)
    assert DateTime.to_unix(updated.updated_at) > DateTime.to_unix(note.updated_at)
    assert {:ok, %{note: deleted}} = Compat.delete_note(note.id, 2, nil)
    assert deleted.updated_at == updated.updated_at
    assert {:ok, %{note: restored}} = Compat.restore_note(note.id, 3, nil)
    assert restored.updated_at == updated.updated_at
  end
end
