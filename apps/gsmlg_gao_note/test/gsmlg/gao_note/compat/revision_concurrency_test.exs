defmodule GSMLG.GaoNote.Compat.RevisionConcurrencyTest do
  use GSMLG.GaoNote.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias GSMLG.GaoNote.Compat
  alias GSMLG.GaoNote.{Label, LabelSetting, Log, Note}

  test "separate connections racing the same revision commit exactly one complete mutation" do
    suffix = Ecto.UUID.generate()
    keys = ["revision-race-first-#{suffix}", "revision-race-second-#{suffix}"]

    note =
      outside_sandbox(fn ->
        {:ok, note} =
          Compat.save_note(%{title: "Before", content: "Body", labels: [], attachments: []}, nil)

        note
      end)

    on_exit(fn ->
      outside_sandbox(fn ->
        Repo.delete_all(from(log in Log, where: log.note_id == ^note.id))
        Repo.delete_all(from(label in Label, where: label.note_id == ^note.id))
        Repo.delete_all(from(existing in Note, where: existing.id == ^note.id))
        Repo.delete_all(from(setting in LabelSetting, where: setting.name in ^keys))
      end)
    end)

    parent = self()

    holder =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        try do
          Repo.transaction(fn ->
            Repo.one!(from(existing in Note, where: existing.id == ^note.id, lock: "FOR UPDATE"))
            send(parent, {:row_locked, self()})

            receive do
              :release -> :ok
            after
              10_000 -> raise "revision race lock holder timed out"
            end
          end)
        after
          Sandbox.checkin(Repo)
        end
      end)

    assert_receive {:row_locked, holder_pid}, 2_000
    assert holder_pid == holder.pid

    writers =
      Enum.zip(["First", "Second"], keys)
      |> Enum.map(fn {title, key} ->
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            %{rows: [[backend_pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
            send(parent, {:writer_ready, self(), backend_pid})

            receive do
              :run -> Compat.patch_note(note.id, 1, %{title: title, labels: [{key, title}]}, nil)
            after
              10_000 -> raise "revision race writer timed out"
            end
          after
            Sandbox.checkin(Repo)
          end
        end)
      end)

    results =
      try do
        backend_pids =
          Enum.map(writers, fn writer ->
            writer_pid = writer.pid
            assert_receive {:writer_ready, ^writer_pid, backend_pid}, 2_000
            backend_pid
          end)

        assert length(Enum.uniq(backend_pids)) == 2
        Enum.each(writers, &send(&1.pid, :run))
        assert both_blocked?(backend_pids, System.monotonic_time(:millisecond) + 3_000)
        send(holder.pid, :release)
        assert {:ok, :ok} = Task.await(holder, 5_000)
        Task.await_many(writers, 5_000)
      after
        send(holder.pid, :release)
        Enum.each([holder | writers], &Task.shutdown(&1, :brutal_kill))
      end

    assert [{:ok, %{note: winner, changed: true}}] = Enum.filter(results, &match?({:ok, _}, &1))

    assert [{:error, {:revision_conflict, %{expected_revision: 1, current_revision: 2}}}] =
             Enum.filter(results, &match?({:error, _}, &1))

    assert winner.revision == 2

    outside_sandbox(fn ->
      persisted = Compat.get_note(note.id)
      assert persisted.title == winner.title
      assert persisted.revision == 2
      assert persisted.content == "Body"
      assert [{key, value}] = Enum.map(persisted.labels, &{&1.label_setting.name, &1.value})
      assert value == winner.title
      assert key == Enum.at(keys, if(winner.title == "First", do: 0, else: 1))

      assert Repo.aggregate(
               from(log in Log, where: log.note_id == ^note.id and log.action == "update"),
               :count
             ) == 1

      assert Repo.aggregate(from(setting in LabelSetting, where: setting.name in ^keys), :count) ==
               1
    end)
  end

  defp both_blocked?(pids, deadline) do
    count =
      outside_sandbox(fn ->
        %{rows: [[count]]} =
          SQL.query!(
            Repo,
            "SELECT count(*) FROM pg_stat_activity WHERE pid = ANY($1::int[]) AND wait_event_type = 'Lock'",
            [pids]
          )

        count
      end)

    cond do
      count == length(pids) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        both_blocked?(pids, deadline)
    end
  end

  defp outside_sandbox(operation) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        operation.()
      after
        Sandbox.checkin(Repo)
      end
    end)
    |> Task.await(10_000)
  end
end
