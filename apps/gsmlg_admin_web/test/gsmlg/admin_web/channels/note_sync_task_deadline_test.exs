defmodule GSMLG.AdminWeb.NoteSyncTaskDeadlineTest do
  use ExUnit.Case, async: true

  alias GSMLG.AdminWeb.NoteSyncChannel

  @session_tasks [
    :inventory_task,
    :pending_task,
    :checkout_task,
    :confirmation_task,
    :recovery_task
  ]

  for key <- @session_tasks do
    test "#{key} waits for active apply within a single bounded extension" do
      key = unquote(key)
      task = task_timer(10_000)
      apply_task = task_timer(60_000)
      socket = socket(%{key => task, :apply_task => apply_task})

      assert {:noreply, updated} = NoteSyncChannel.handle_info({:task_deadline, task.ref}, socket)
      deferred = updated.assigns[key]
      assert deferred.ref == task.ref
      assert deferred.pid == task.pid
      assert Process.read_timer(task.timer) == false
      assert Process.read_timer(deferred.timer) in 68_000..70_000

      # A stale copy of the original deadline cannot renew or end the extension.
      assert {:noreply, repeated} =
               NoteSyncChannel.handle_info({:task_deadline, task.ref}, updated)

      assert repeated.assigns[key].timer == deferred.timer

      # A subsequent apply must not grant another extension to this task.
      next_apply = task_timer(90_000)
      repeated = Phoenix.Socket.assign(repeated, :apply_task, next_apply)

      assert {:noreply, unchanged} =
               NoteSyncChannel.handle_info({:task_deadline, task.ref}, repeated)

      assert unchanged.assigns[key].timer == deferred.timer
      Process.cancel_timer(deferred.timer)

      assert {:stop, {:shutdown, :sync_session_error}, _} =
               NoteSyncChannel.handle_info({:task_deadline, task.ref}, unchanged)
    end

    test "#{key} keeps its ordinary deadline without active apply" do
      key = unquote(key)
      task = task_timer(10_000)
      socket = socket(%{key => task})

      assert {:stop, {:shutdown, :sync_session_error}, _} =
               NoteSyncChannel.handle_info({:task_deadline, task.ref}, socket)
    end
  end

  test "a session task waits once for a query holding session locks" do
    task = task_timer(10_000)
    query = task_timer(60_000)
    socket = socket(%{inventory_task: task, query_task: query})

    assert {:noreply, updated} = NoteSyncChannel.handle_info({:task_deadline, task.ref}, socket)
    deferred = updated.assigns.inventory_task
    assert deferred.ref == task.ref
    assert deferred.pid == task.pid
    assert Process.read_timer(task.timer) == false
    assert Process.read_timer(deferred.timer) in 68_000..70_000

    assert {:noreply, repeated} =
             NoteSyncChannel.handle_info({:task_deadline, task.ref}, updated)

    assert repeated.assigns.inventory_task.timer == deferred.timer
    repeated = Phoenix.Socket.assign(repeated, :apply_task, task_timer(90_000))
    Process.cancel_timer(deferred.timer)

    assert {:stop, {:shutdown, :sync_session_error}, _} =
             NoteSyncChannel.handle_info({:task_deadline, task.ref}, repeated)
  end

  for {apply_delay, query_delay} <- [{30_000, 60_000}, {60_000, 30_000}] do
    test "a session task uses the longer lock holder budget with apply #{apply_delay} and query #{query_delay}" do
      task = task_timer(10_000)

      socket =
        socket(%{
          checkout_task: task,
          apply_task: task_timer(unquote(apply_delay)),
          query_task: task_timer(unquote(query_delay))
        })

      assert {:noreply, updated} = NoteSyncChannel.handle_info({:task_deadline, task.ref}, socket)
      assert Process.read_timer(updated.assigns.checkout_task.timer) in 68_000..70_000
    end
  end

  test "an expired query cannot extend a short task" do
    task = task_timer(10_000)
    query = task_timer(60_000)
    Process.cancel_timer(query.timer)

    assert {:stop, {:shutdown, :sync_session_error}, _} =
             NoteSyncChannel.handle_info(
               {:task_deadline, task.ref},
               socket(%{inventory_task: task, query_task: query})
             )
  end

  test "a query's own deadline is not extended by an apply" do
    query = task_timer(60_000)

    assert {:stop, {:shutdown, :sync_session_error}, _} =
             NoteSyncChannel.handle_info(
               {:task_deadline, query.ref},
               socket(%{query_task: query, apply_task: task_timer(90_000)})
             )
  end

  test "apply's own deadline always closes the session" do
    apply_task = task_timer(60_000)
    socket = socket(%{apply_task: apply_task, pending_task: task_timer(10_000)})

    assert {:stop, {:shutdown, :sync_session_error}, _} =
             NoteSyncChannel.handle_info({:task_deadline, apply_task.ref}, socket)
  end

  test "an expired apply cannot extend a short task" do
    task = task_timer(10_000)
    apply_task = task_timer(60_000)
    Process.cancel_timer(apply_task.timer)

    assert {:stop, {:shutdown, :sync_session_error}, _} =
             NoteSyncChannel.handle_info(
               {:task_deadline, task.ref},
               socket(%{checkout_task: task, apply_task: apply_task})
             )
  end

  for key <- [:blob_task, :read_task, :chunk_task] do
    test "#{key} is not extended by concurrent apply" do
      key = unquote(key)
      task = task_timer(10_000)

      assert {:stop, {:shutdown, :sync_session_error}, _} =
               NoteSyncChannel.handle_info(
                 {:task_deadline, task.ref},
                 socket(%{key => task, :apply_task => task_timer(60_000)})
               )
    end
  end

  test "an unrelated expired task reference is ignored" do
    socket = socket(%{apply_task: task_timer(60_000)})
    assert {:noreply, ^socket} = NoteSyncChannel.handle_info({:task_deadline, make_ref()}, socket)
  end

  defp task_timer(delay) do
    ref = make_ref()
    timer = Process.send_after(self(), {:task_deadline, ref}, delay)
    on_exit(fn -> Process.cancel_timer(timer) end)
    %{ref: ref, pid: self(), timer: timer}
  end

  defp socket(tasks) do
    %Phoenix.Socket{
      assigns:
        Map.merge(
          %{
            session_peer: %{id: Ecto.UUID.generate()},
            incoming: nil,
            outgoing: nil,
            apply_task: nil
          },
          tasks
        )
    }
  end
end
