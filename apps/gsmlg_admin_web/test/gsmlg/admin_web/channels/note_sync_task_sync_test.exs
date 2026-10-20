defmodule GSMLG.AdminWeb.NoteSyncTaskSyncTest do
  use ExUnit.Case, async: true
  alias GSMLG.AdminWeb.NoteSync.TaskSync

  test "admission deduplicates active and terminal work and rejects changed commands" do
    origin = Ecto.UUID.generate()
    ledger = TaskSync.new(origin)
    command = command(origin, 1)
    assert {:new, ledger, queued} = TaskSync.admit(ledger, command)
    assert queued["state"] == "queued"
    assert {:replay, ^ledger, ^queued} = TaskSync.admit(ledger, command)

    assert {:error, "task_id_conflict"} =
             TaskSync.admit(ledger, put_in(command, ["payload"], %{"changed" => true}))

    {ledger, done} =
      TaskSync.update(ledger, command["task_id"], "succeeded", "complete", %{}, %{}, nil)

    assert done["status_seq"] > queued["status_seq"]
    assert {:replay, ^ledger, ^done} = TaskSync.admit(ledger, command)

    assert {^ledger, ^done} =
             TaskSync.update(ledger, command["task_id"], "failed", "failed", %{}, nil, %{
               "code" => "busy",
               "retryable" => true
             })
  end

  test "eviction keeps the high water mark and never executes retired work" do
    origin = Ecto.UUID.generate()

    ledger =
      Enum.reduce(1..66, TaskSync.new(origin), fn sequence, ledger ->
        command = command(origin, sequence)
        {:new, ledger, _} = TaskSync.admit(ledger, command)

        {ledger, _} =
          TaskSync.update(ledger, command["task_id"], "succeeded", "complete", %{}, %{}, nil)

        ledger
      end)

    assert map_size(ledger.entries) == 64
    assert {:error, "retired"} = TaskSync.admit(ledger, command(origin, 1))
    assert {:error, "invalid_task_id"} = TaskSync.admit(ledger, command(origin, 68))
    assert {:error, "invalid_task_id"} = TaskSync.admit(ledger, command(Ecto.UUID.generate(), 67))
  end

  test "busy tasks consume their sequence without displacing active work" do
    origin = Ecto.UUID.generate()
    {:new, ledger, first} = TaskSync.admit(TaskSync.new(origin), command(origin, 1))
    {:busy, ledger, busy} = TaskSync.admit(ledger, command(origin, 2))
    assert busy["state"] == "failed"
    assert busy["error"] == %{"code" => "busy", "retryable" => true}
    assert TaskSync.get(ledger, first["task_id"]) == {:ok, first}
    assert {:replay, ^ledger, ^busy} = TaskSync.admit(ledger, command(origin, 2))
    assert {:new, _, _} = TaskSync.admit(ledger, command(origin, 3, "inventory_complete"))
  end

  test "status codecs enforce terminal outcomes and immutable monotonic authority" do
    id = "#{Ecto.UUID.generate()}:1"

    running = %{
      "task_id" => id,
      "status_seq" => 1,
      "state" => "running",
      "phase" => "checking",
      "progress" => %{},
      "result" => nil,
      "error" => nil
    }

    assert TaskSync.valid_status?(running)
    refute TaskSync.valid_status?(Map.put(running, "result", %{}))
    refute TaskSync.valid_status?(Map.put(running, "extra", true))
    refute TaskSync.valid_status?(Map.put(running, "status_seq", 0))

    failed = %{
      running
      | "status_seq" => 2,
        "state" => "failed",
        "error" => %{"code" => "busy", "retryable" => true}
    }

    assert TaskSync.valid_status?(failed)

    refute TaskSync.valid_status?(
             put_in(failed, ["error"], %{"code" => "busy", "message" => "raw"})
           )

    assert {:ok, ^failed} = TaskSync.accept_status(running, failed)

    assert {:error, :status_conflict} =
             TaskSync.accept_status(running, %{running | "phase" => "changed"})

    assert {:error, :terminal_conflict} =
             TaskSync.accept_status(failed, %{failed | "status_seq" => 3})
  end

  test "manager status uses session-global ordering and rejects malformed progress" do
    alias GSMLG.AdminWeb.NoteSync.InventoryManager
    manager = InventoryManager.new("/tmp/unused-task-test", Ecto.UUID.generate())
    progress = InventoryManager.progress(manager)
    status = %{"round_id" => manager.round_id, "status_seq" => 1, "progress" => progress}
    assert {:ok, ^status} = InventoryManager.accept_status(nil, status)
    assert {:ok, ^status} = InventoryManager.accept_status(status, status)
    next = %{status | "round_id" => Ecto.UUID.generate(), "status_seq" => 2}
    assert {:ok, ^next} = InventoryManager.accept_status(status, next)
    assert {:ok, ^next} = InventoryManager.accept_status(next, status)

    assert {:error, "status_conflict"} =
             InventoryManager.accept_status(next, %{next | "round_id" => Ecto.UUID.generate()})

    refute InventoryManager.valid_progress?(Map.put(progress, "round_id", manager.round_id))
    refute InventoryManager.valid_progress?(Map.put(progress, "page_size", 33))
    refute InventoryManager.valid_progress?(Map.put(progress, "checked_notes", -1))
    refute InventoryManager.valid_progress?(Map.delete(progress, "total_notes"))
    assert InventoryManager.valid_progress?(Map.put(progress, "blocked_notes", 1))
    assert InventoryManager.valid_progress?(Map.put(progress, "state", nil))
    assert InventoryManager.valid_progress?(Map.put(progress, "error", nil))
  end

  defp command(origin, sequence, operation \\ "inventory_start"),
    do: %{"task_id" => "#{origin}:#{sequence}", "operation" => operation, "payload" => %{}}
end
