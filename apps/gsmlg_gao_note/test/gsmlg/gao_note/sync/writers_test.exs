defmodule GSMLG.GaoNote.Sync.WritersTest do
  use GSMLG.GaoNote.DataCase, async: true

  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{Compat, LabelSetting}
  alias GSMLG.GaoNote.Sync

  setup do
    assert {:ok, peer} =
             Sync.register_peer(%{
               node_id: Ecto.UUID.generate(),
               certificate_fingerprint:
                 :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
               actor_id: "sync-test",
               allowed_selectors: ["project=bear_note"]
             })

    assert {:ok, _} = Sync.select(peer.id, ["project=bear_note"])
    %{peer: peer}
  end

  test "native complete writes coalesce and noops keep their version", %{peer: peer} do
    assert {:ok, note} =
             GaoNote.create_note(
               %{title: "Native", content: "body", labels: ["project=bear_note"]},
               nil
             )

    [first] = Sync.pending(peer.id)

    assert first["snapshot"]["labels"] == [
             %{
               "key" => "project",
               "value" => "bear_note",
               "description" => "",
               "value_type" => "text"
             }
           ]

    assert {:ok, _} = GaoNote.update_note_fields(note, %{content: "body"}, nil)
    assert [^first] = Sync.pending(peer.id)
    assert {:ok, updated} = GaoNote.update_note_fields(note, %{content: "changed"}, nil)
    [second] = Sync.pending(peer.id)
    assert second["snapshot"]["content"] == "changed"
    refute second["version"] == first["version"]
    assert {:ok, _} = GaoNote.delete_note(updated, nil)
    [deleted] = Sync.pending(peer.id)
    assert is_integer(deleted["snapshot"]["deleted_at"])
    assert {:ok, _} = GaoNote.restore_note(updated, nil)
    [restored] = Sync.pending(peer.id)
    assert restored["snapshot"]["deleted_at"] == nil
  end

  test "compat bulk and catalog metadata writers capture complete changed snapshots", %{
    peer: peer
  } do
    assert {:ok, note} =
             Compat.save_note(
               %{title: "Compat", content: "body", labels: [{"project", "bear_note"}]},
               nil
             )

    assert {:ok, %{updated: 1}} =
             Compat.bulk_update_note_labels(
               %{selector: "project=bear_note", set: [{"team", "core"}], remove: []},
               nil
             )

    [bulk] = Sync.pending(peer.id)
    assert Enum.any?(bulk["snapshot"]["labels"], &(&1["key"] == "team" and &1["value"] == "core"))
    setting = Repo.get_by!(LabelSetting, name: "project")
    assert {:ok, _} = GaoNote.update_label_setting(setting, %{description: "Exact metadata"})
    [catalog] = Sync.pending(peer.id)
    assert Enum.any?(catalog["snapshot"]["labels"], &(&1["description"] == "Exact metadata"))
    assert Compat.get_note(note.id).revision == 2
    refute catalog["version"] == bulk["version"]
    assert {:ok, _} = Compat.delete_note(note.id, 2, nil)
    assert {:ok, _} = Compat.permanently_delete_note(note.id, 3, nil)
    [purge] = Sync.pending(peer.id)
    assert purge["kind"] == "purge"
    assert purge["snapshot"] == nil
  end

  test "native full updates and batch label lifecycle capture the final set", %{peer: peer} do
    assert {:ok, note} =
             GaoNote.create_note(
               %{title: "Batch", content: "body", labels: ["project=bear_note"]},
               nil
             )

    assert {:ok, _} =
             GaoNote.update_note(
               note,
               %{
                 content: "complete",
                 labels: ["project=bear_note", "team=core"],
                 attachments: []
               },
               nil
             )

    setting = Repo.get_by!(LabelSetting, name: "team")

    assert {:ok, %{changed: 1}} =
             GaoNote.batch_mutate_note_labels(
               [note.id],
               {:edit,
                %{
                  match: %{label_setting_id: setting.id, value: {:exact, "core"}},
                  replacement: %{label_setting_id: setting.id, value: "infra"}
                }},
               nil
             )

    [updated] = Sync.pending(peer.id)
    assert updated["snapshot"]["content"] == "complete"

    assert Enum.any?(
             updated["snapshot"]["labels"],
             &(&1["key"] == "team" and &1["value"] == "infra")
           )

    assert {:ok, %{deleted: 1}} = GaoNote.batch_delete_notes([note.id], nil)
    [trashed] = Sync.pending(peer.id)
    assert is_integer(trashed["snapshot"]["deleted_at"])
    assert {:ok, %{purged: 1}} = GaoNote.batch_permanently_delete_notes([note.id], nil)
    assert [%{"kind" => "purge", "snapshot" => nil}] = Sync.pending(peer.id)
  end

  test "compat patch and catalog rename or removal capture changed metadata", %{peer: peer} do
    assert {:ok, note} =
             Compat.save_note(
               %{
                 title: "Catalog",
                 content: "body",
                 labels: [{"project", "bear_note"}, {"extra", "1"}]
               },
               nil
             )

    assert {:ok, %{changed: true}} = Compat.patch_note(note.id, 1, %{content: "patched"}, nil)
    [patched] = Sync.pending(peer.id)
    assert patched["snapshot"]["content"] == "patched"
    setting = Repo.get_by!(LabelSetting, name: "extra")
    assert {:ok, renamed} = GaoNote.update_label_setting(setting, %{name: "renamed"})
    [event] = Sync.pending(peer.id)
    assert Enum.any?(event["snapshot"]["labels"], &(&1["key"] == "renamed"))
    assert {:ok, typed} = GaoNote.update_label_setting(renamed, %{value_type: "number"})
    [typed_event] = Sync.pending(peer.id)

    assert Enum.any?(
             typed_event["snapshot"]["labels"],
             &(&1["key"] == "renamed" and &1["value_type"] == "number")
           )

    assert Compat.get_note(note.id).revision == 3
    assert {:ok, _} = GaoNote.delete_label_setting(typed)
    [removed] = Sync.pending(peer.id)
    refute Enum.any?(removed["snapshot"]["labels"], &(&1["key"] == "renamed"))
    assert Compat.get_note(note.id).revision == 4
  end

  test "sync state rolls back with the business transaction", %{peer: peer} do
    assert {:error, :rollback_test} =
             Repo.transaction(fn ->
               assert {:ok, _} =
                        GaoNote.create_note(
                          %{title: "Rolled back", content: "body", labels: ["project=bear_note"]},
                          nil
                        )

               assert [_] = Sync.pending(peer.id)
               Repo.rollback(:rollback_test)
             end)

    assert [] = Sync.pending(peer.id)
    assert [] = GaoNote.list_notes()
  end
end
