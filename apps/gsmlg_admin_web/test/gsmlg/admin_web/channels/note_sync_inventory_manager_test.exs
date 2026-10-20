defmodule GSMLG.AdminWeb.NoteSyncInventoryManagerTest do
  use GSMLG.AdminWeb.NoteSyncAutoCase, async: false
  import Ecto.Query
  alias GSMLG.AdminWeb.NoteSync.InventoryManager
  alias GSMLG.GaoNote.{Label, LabelSetting, Note, Sync}
  alias GSMLG.GaoNote.Sync.{Engine, Store}
  alias GSMLG.Repo

  test "round classifications count each note once and replace a recovered blocked outcome" do
    root = Path.join(System.tmp_dir!(), "gaonote-classifications-" <> Ecto.UUID.generate())
    manager = InventoryManager.new(root, Ecto.UUID.generate())
    on_exit(fn -> File.rm_rf(root) end)

    manager =
      manager
      |> InventoryManager.classify(id(1), :equal)
      |> InventoryManager.classify(id(2), :planned)
      |> InventoryManager.classify(id(3), :superseded)
      |> InventoryManager.classify(id(4), :blocked)

    expected = %{
      "equal_notes" => 1,
      "planned_notes" => 2,
      "superseded_notes" => 1,
      "blocked_notes" => 1
    }

    assert Map.take(InventoryManager.progress(manager), Map.keys(expected)) == expected

    retried =
      manager
      |> InventoryManager.classify(id(1), :equal)
      |> InventoryManager.classify(id(2), :planned)
      |> InventoryManager.classify(id(3), :superseded)
      |> InventoryManager.classify(id(4), :blocked)

    assert InventoryManager.progress(retried) == InventoryManager.progress(manager)

    recovered = InventoryManager.classify(retried, id(4), :planned)
    progress = InventoryManager.progress(recovered)
    assert progress["planned_notes"] == 2
    assert progress["blocked_notes"] == 0
    assert InventoryManager.valid_progress?(progress)

    # Completing a page must not discard the deduplication evidence for later
    # pending polls, and a new round must start with fresh classification counts.
    next_page = recovered |> InventoryManager.page_loaded(4, 4) |> InventoryManager.page_done()
    assert InventoryManager.classify(next_page, id(1), :equal) == next_page
    fresh = InventoryManager.new(root, Ecto.UUID.generate())
    assert InventoryManager.progress(fresh)["equal_notes"] == 0

    assert InventoryManager.progress(InventoryManager.classify(fresh, id(1), :equal))[
             "equal_notes"
           ] == 1
  end

  test "snapshot lanes preserve exact authorized identities and prioritize pending before lower audit IDs",
       %{label: label} do
    setting = Repo.insert!(%LabelSetting{name: label})
    initial = Enum.map(1..70, &insert_note(&1, setting.id, "selected"))
    private = insert_note(90, setting.id, "private")

    {:ok, %{peer: peer}} =
      Sync.join(%{
        "protocol_version" => 1,
        "node_id" => Ecto.UUID.generate(),
        "selectors" => [label <> "=selected"],
        "max_blob_bytes" => 536_870_912
      })

    pending = Enum.map(40..65, &id/1)
    Enum.each(pending, &Store.put("pending", &1, %{"event" => %{}}, peer.id, &1))
    tombstone = id(80)
    unauthorized = id(81)
    Store.put("member", tombstone, %{"authorized" => true}, peer.id, tombstone)
    Store.put("member", unauthorized, %{"authorized" => false}, peer.id, unauthorized)
    Store.put("member", private, %{"authorized" => false}, peer.id, private)
    root = Path.join(System.tmp_dir!(), "gaonote-manager-test-" <> Ecto.UUID.generate())
    manager = InventoryManager.new(root, Ecto.UUID.generate())
    on_exit(fn -> File.rm_rf(root) end)
    owner = self()
    queries = :atomics.new(1, [])
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:gsmlg, :repo, :query],
      fn _, _, metadata, _ ->
        if String.contains?(metadata.query, ") cohort") do
          send(owner, {:source_limit, List.last(metadata.params)})
          :atomics.add(queries, 1, 1)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    worker =
      Task.Supervisor.async_nolink(GSMLG.TaskSupervisor, fn ->
        InventoryManager.scan(peer, manager, fn progress ->
          if progress["pages_scanned"] == 1 and not progress["scan_complete"] do
            send(owner, {:first_page, self(), progress})

            receive do
              :continue_scan -> :ok
            after
              5_000 -> raise "snapshot barrier timed out"
            end
          end
        end)
      end)

    try do
      assert_receive {:first_page, producer, %{"notes_scanned" => 32, "scan_complete" => false}},
                     5_000

      first = read_ids(manager, 1)
      assert length(first) == 32
      assert Enum.take(first, 8) == Enum.take(pending, 8)
      assert Enum.at(first, 8) == id(1)
      # These writes commit after the source snapshot. A lower UUID must wait for
      # the later durable-change pass, and deleting a later ID cannot shrink it.
      inserted = insert_note(0, setting.id, "selected")
      Store.put("pending", inserted, %{"event" => %{}}, peer.id, inserted)
      Repo.delete_all(from(n in Note, where: n.id == ^id(70)))
      send(producer, :continue_scan)
      assert {:ok, source} = Task.await(worker, 5_000)
      assert source["notes_scanned"] == 71
      assert source["pages_scanned"] == 3
      assert source["scan_complete"]
      pages = Enum.map(1..3, &read_ids(manager, &1))
      assert Enum.map(pages, &length/1) == [32, 32, 7]
      ids = List.flatten(pages)
      assert Enum.sort(ids) == Enum.sort(initial ++ [tombstone])
      assert length(Enum.uniq(ids)) == 71
      refute inserted in ids
      refute private in ids
      refute unauthorized in ids
      calls = :atomics.get(queries, 1)
      assert calls > 0
      Enum.each(1..calls, fn _ -> assert_receive {:source_limit, 32} end)
      assert {:ok, %{ids: changed}} = Engine.pending_page(peer, nil)
      assert inserted in changed
      assert :atomics.get(queries, 1) == calls
    after
      send(worker.pid, :continue_scan)
      Task.shutdown(worker, :brutal_kill)
    end
  end

  test "post-scan classifications expand totals while preserving the original scanned cohort" do
    root = Path.join(System.tmp_dir!(), "gaonote-classification-totals-" <> Ecto.UUID.generate())
    manager = InventoryManager.new(root, Ecto.UUID.generate())
    on_exit(fn -> File.rm_rf(root) end)

    source = %{
      manager.source
      | "scan_complete" => true,
        "notes_scanned" => 2,
        "pages_scanned" => 1
    }

    manager =
      manager
      |> InventoryManager.observe_source(source)
      |> InventoryManager.page_loaded(2, 2)
      |> InventoryManager.page_done()
      |> InventoryManager.classify(id(1), :equal)
      |> InventoryManager.classify(id(2), :planned)

    assert InventoryManager.progress(manager)["total_notes"] == 2
    assert InventoryManager.progress(manager)["checked_notes"] == 2
    manager = InventoryManager.classify(manager, id(3), :planned)
    progress = InventoryManager.progress(manager)
    assert progress["total_notes"] == 3
    assert progress["checked_notes"] == 3
    assert progress["notes_scanned"] == 2
    assert progress["equal_notes"] + progress["planned_notes"] + progress["superseded_notes"] == 3

    manager = InventoryManager.classify(manager, id(2), :equal)
    progress = InventoryManager.progress(manager)
    assert progress["total_notes"] == 3
    assert progress["checked_notes"] == 3
    assert progress["equal_notes"] == 2
    assert progress["planned_notes"] == 1
  end

  test "a delivered note stays resolved during audit while a later blocked retry remains visible" do
    root =
      Path.join(System.tmp_dir!(), "gaonote-delivered-classifications-" <> Ecto.UUID.generate())

    manager = InventoryManager.new(root, Ecto.UUID.generate())
    on_exit(fn -> File.rm_rf(root) end)

    delivered =
      manager
      |> InventoryManager.classify(id(1), :planned)
      |> InventoryManager.classify(id(1), :delivered)

    assert InventoryManager.classify(delivered, id(1), :equal) == delivered
    assert InventoryManager.classify(delivered, id(1), :superseded) == delivered
    progress = InventoryManager.progress(delivered)
    assert progress["equal_notes"] == 0
    assert progress["planned_notes"] == 1
    assert progress["superseded_notes"] == 0

    blocked = InventoryManager.classify(delivered, id(1), :blocked)
    progress = InventoryManager.progress(blocked)
    assert progress["planned_notes"] == 1
    assert progress["blocked_notes"] == 1
    assert InventoryManager.classify(blocked, id(1), :superseded) == blocked

    recovered = InventoryManager.classify(blocked, id(1), :planned)
    progress = InventoryManager.progress(recovered)
    assert progress["planned_notes"] == 1
    assert progress["blocked_notes"] == 0
    assert InventoryManager.classify(recovered, id(1), :equal) == recovered
  end

  defp insert_note(number, setting, value) do
    note = Repo.insert!(%Note{id: id(number), title: "cohort", content: "body"})
    Repo.insert!(%Label{note_id: note.id, label_setting_id: setting, value: value})
    note.id
  end

  defp id(number),
    do:
      "00000000-0000-4000-8000-" <>
        String.pad_leading(String.downcase(Integer.to_string(number, 16)), 12, "0")

  defp read_ids(manager, page),
    do:
      manager.directory
      |> Path.join("page-#{page}.ids")
      |> File.read!()
      |> String.split("\n", trim: true)
end
