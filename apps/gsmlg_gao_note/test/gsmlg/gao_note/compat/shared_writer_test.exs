defmodule GSMLG.GaoNote.Compat.SharedWriterTest do
  use GSMLG.GaoNote.DataCase, async: false

  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{CategorySetting, LabelSetting, Note}
  alias GSMLG.GaoNote.Compat
  alias GSMLG.GaoNote.Compat.Catalog
  alias GSMLG.Storage.StorageFile
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias GSMLG.GaoNote.{Label, Log}

  test "legacy catalog mutations return tagged errors for a concurrently deleted setting" do
    {:ok, setting} = Compat.define_label_key("missing-legacy", "", nil)
    Repo.delete!(setting)

    assert {:error, :catalog_not_found} =
             GaoNote.update_label_setting(setting, %{description: "after deletion"}, nil)

    assert {:error, :catalog_not_found} = GaoNote.delete_label_setting(setting, nil)
  end

  for operation <- [:update, :delete] do
    test "compat catalog #{operation} succeeds when another delete wins after its lookup" do
      operation = unquote(operation)
      key = "shared-missing-#{Ecto.UUID.generate()}"

      setting =
        outside_sandbox(fn ->
          {:ok, setting} = Compat.define_label_key(key, "original", nil)
          setting
        end)

      on_exit(fn ->
        outside_sandbox(fn ->
          Repo.delete_all(from(log in Log, where: log.entity_id == ^setting.id))
          Repo.delete_all(from(existing in LabelSetting, where: existing.id == ^setting.id))
        end)
      end)

      parent = self()

      holder =
        Task.async(fn ->
          with_connection(fn ->
            Repo.transaction(fn ->
              locked =
                Repo.one!(
                  from(existing in LabelSetting,
                    where: existing.id == ^setting.id,
                    lock: "FOR UPDATE"
                  )
                )

              send(parent, :catalog_delete_locked)

              receive do
                :delete -> Repo.delete!(locked)
              after
                10_000 -> raise "catalog deletion holder timed out"
              end
            end)
          end)
        end)

      assert_receive :catalog_delete_locked, 2_000

      writer =
        Task.async(fn ->
          with_connection(fn ->
            %{rows: [[pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
            send(parent, {:missing_catalog_writer, pid})
            mutate_missing_catalog(operation, key)
          end)
        end)

      try do
        assert_receive {:missing_catalog_writer, pid}, 2_000
        assert blocked?(pid, System.monotonic_time(:millisecond) + 3_000)
        send(holder.pid, :delete)
        assert {:ok, %{id: id}} = Task.await(holder, 5_000)
        assert id == setting.id
        assert {:ok, nil} = Task.await(writer, 5_000)
        outside_sandbox(fn -> assert Repo.get(LabelSetting, setting.id) == nil end)
      after
        send(holder.pid, :delete)
        Enum.each([holder, writer], &Task.shutdown(&1, :brutal_kill))
      end
    end
  end

  test "catalog and note writer deadlock returns tagged errors with whole transaction rollback" do
    key = "shared-deadlock-#{Ecto.UUID.generate()}"

    {setting, note} =
      outside_sandbox(fn ->
        note = save([{key, "original"}])
        {Repo.get_by!(LabelSetting, name: key), note}
      end)

    on_exit(fn ->
      outside_sandbox(fn ->
        Repo.delete_all(
          from(log in Log, where: log.note_id == ^note.id or log.entity_id == ^setting.id)
        )

        Repo.delete_all(from(label in Label, where: label.note_id == ^note.id))
        Repo.delete_all(from(existing in Note, where: existing.id == ^note.id))
        Repo.delete_all(from(existing in LabelSetting, where: existing.id == ^setting.id))
      end)
    end)

    parent = self()

    holder =
      Task.async(fn ->
        with_connection(fn ->
          try do
            Repo.transaction(fn ->
              locked =
                Repo.one!(
                  from(existing in Note, where: existing.id == ^note.id, lock: "FOR UPDATE")
                )

              send(parent, :deadlock_note_locked)

              receive do
                :rewrite ->
                  Repo.delete_all(from(label in Label, where: label.note_id == ^note.id))

                  %Label{}
                  |> Label.changeset(%{
                    note_id: note.id,
                    label_setting_id: setting.id,
                    value: "changed"
                  })
                  |> Repo.insert!()

                  {:ok, updated} = GaoNote.advance_revision(locked)
                  updated
              after
                10_000 -> raise "deadlock note writer timed out"
              end
            end)
          rescue
            error in Postgrex.Error -> {:error, error}
          end
        end)
      end)

    assert_receive :deadlock_note_locked, 2_000

    catalog =
      Task.async(fn ->
        with_connection(fn ->
          %{rows: [[pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
          send(parent, {:deadlock_catalog_backend, pid})
          GaoNote.update_label_setting(setting, %{name: key <> "-renamed"}, nil)
        end)
      end)

    try do
      assert_receive {:deadlock_catalog_backend, pid}, 2_000
      assert blocked?(pid, System.monotonic_time(:millisecond) + 3_000)
      send(holder.pid, :rewrite)
      catalog_result = Task.await(catalog, 5_000)
      holder_result = Task.await(holder, 5_000)

      results = [catalog_result, holder_result]

      assert [{:error, %Postgrex.Error{postgres: %{code: :deadlock_detected}}}] =
               Enum.filter(results, &match?({:error, _}, &1))

      assert length(Enum.filter(results, &match?({:ok, _}, &1))) == 1

      outside_sandbox(fn ->
        persisted = Compat.get_note(note.id)
        assert persisted.revision == 2

        case catalog_result do
          {:ok, _} -> assert Catalog.pairs(persisted) == [{key <> "-renamed", "original"}]
          {:error, _} -> assert Catalog.pairs(persisted) == [{key, "changed"}]
        end
      end)
    after
      Enum.each([holder, catalog], &Task.shutdown(&1, :brutal_kill))
    end
  end

  for operation <- [:rename, :delete] do
    test "catalog #{operation} blocks unrelated label insertion until its mutation commits" do
      operation = unquote(operation)
      key = "shared-insert-#{Ecto.UUID.generate()}"

      {setting, affected, unrelated} =
        outside_sandbox(fn ->
          affected = save([{key, "value"}])
          {Repo.get_by!(LabelSetting, name: key), affected, save([])}
        end)

      on_exit(fn ->
        outside_sandbox(fn ->
          ids = [affected.id, unrelated.id]

          Repo.delete_all(
            from(log in Log, where: log.note_id in ^ids or log.entity_id == ^setting.id)
          )

          Repo.delete_all(from(label in Label, where: label.note_id in ^ids))
          Repo.delete_all(from(note in Note, where: note.id in ^ids))
          Repo.delete_all(from(existing in LabelSetting, where: existing.id == ^setting.id))
        end)
      end)

      parent = self()

      holder =
        Task.async(fn ->
          with_connection(fn ->
            Repo.transaction(fn ->
              Repo.one!(from(note in Note, where: note.id == ^affected.id, lock: "FOR UPDATE"))
              send(parent, :affected_note_locked)

              receive do
                :release -> :ok
              after
                10_000 -> raise "catalog insertion lock holder timed out"
              end
            end)
          end)
        end)

      assert_receive :affected_note_locked, 2_000

      catalog =
        Task.async(fn ->
          with_connection(fn ->
            %{rows: [[pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
            send(parent, {:catalog_backend, pid})
            mutate_catalog(operation, setting, key)
          end)
        end)

      insertion =
        Task.async(fn ->
          with_connection(fn ->
            %{rows: [[pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
            send(parent, {:insertion_backend, pid})

            receive do
              :insert ->
                Repo.transaction(fn ->
                  note =
                    Repo.one!(
                      from(note in Note, where: note.id == ^unrelated.id, lock: "FOR UPDATE")
                    )

                  with {:ok, _} <-
                         %Label{}
                         |> Label.changeset(%{
                           note_id: note.id,
                           label_setting_id: setting.id,
                           value: "added"
                         })
                         |> Ecto.Changeset.foreign_key_constraint(:label_setting_id,
                           name: :gao_note_taggings_tag_id_fkey
                         )
                         |> Repo.insert(),
                       {:ok, updated} <- GaoNote.advance_revision(note) do
                    updated
                  else
                    {:error, reason} -> Repo.rollback(reason)
                  end
                end)
            after
              10_000 -> raise "unrelated label insertion timed out"
            end
          end)
        end)

      try do
        assert_receive {:catalog_backend, catalog_pid}, 2_000
        assert blocked?(catalog_pid, System.monotonic_time(:millisecond) + 3_000)
        assert_receive {:insertion_backend, insertion_pid}, 2_000
        send(insertion.pid, :insert)
        assert blocked?(insertion_pid, System.monotonic_time(:millisecond) + 3_000)

        send(holder.pid, :release)
        assert {:ok, :ok} = Task.await(holder, 5_000)
        assert {:ok, _} = Task.await(catalog, 5_000)
        insertion_result = Task.await(insertion, 5_000)

        outside_sandbox(fn ->
          assert Repo.get(Note, affected.id).revision == 2
          assert_insertion_outcome(operation, unrelated, key, insertion_result)
        end)
      after
        send(holder.pid, :release)
        Enum.each([holder, catalog, insertion], &Task.shutdown(&1, :brutal_kill))
      end
    end
  end

  for operation <- [:rename, :delete] do
    test "catalog #{operation} locks affected notes in id order before mutation" do
      operation = unquote(operation)
      key = "shared-lock-#{Ecto.UUID.generate()}"

      {setting, [first, second]} =
        outside_sandbox(fn ->
          notes = [save([{key, "one"}]), save([{key, "two"}])] |> Enum.sort_by(& &1.id)
          {Repo.get_by!(LabelSetting, name: key), notes}
        end)

      on_exit(fn ->
        outside_sandbox(fn ->
          ids = [first.id, second.id]

          Repo.delete_all(
            from(log in Log, where: log.note_id in ^ids or log.entity_id == ^setting.id)
          )

          Repo.delete_all(from(label in Label, where: label.note_id in ^ids))
          Repo.delete_all(from(note in Note, where: note.id in ^ids))
          Repo.delete_all(from(existing in LabelSetting, where: existing.id == ^setting.id))
        end)
      end)

      parent = self()

      holder =
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            Repo.transaction(fn ->
              Repo.one!(from(note in Note, where: note.id == ^second.id, lock: "FOR UPDATE"))
              send(parent, :second_note_locked)

              receive do
                :release ->
                  {:ok, updated} = GaoNote.set_labels(second, [], nil)
                  updated
              after
                10_000 -> raise "catalog lock holder timed out"
              end
            end)
          after
            Sandbox.checkin(Repo)
          end
        end)

      assert_receive :second_note_locked, 2_000

      writer =
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            %{rows: [[pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
            send(parent, {:catalog_writer, pid})

            mutate_catalog(operation, setting, key)
          after
            Sandbox.checkin(Repo)
          end
        end)

      try do
        assert_receive {:catalog_writer, pid}, 2_000
        assert blocked?(pid, System.monotonic_time(:millisecond) + 3_000)

        outside_sandbox(fn ->
          assert {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} =
                   SQL.query(Repo, "SELECT id FROM gao_notes WHERE id = $1 FOR UPDATE NOWAIT", [
                     Ecto.UUID.dump!(first.id)
                   ])

          assert Repo.get(Note, first.id).revision == 1
          assert Repo.get(Note, second.id).revision == 1
          assert Repo.get!(LabelSetting, setting.id).name == key
        end)

        send(holder.pid, :release)
        assert {:ok, %{revision: 2}} = Task.await(holder, 5_000)
        assert {:ok, _} = Task.await(writer, 5_000)

        outside_sandbox(fn ->
          assert Repo.get(Note, first.id).revision == 2
          assert Repo.get(Note, second.id).revision == 2
        end)
      after
        send(holder.pid, :release)
        Enum.each([holder, writer], &Task.shutdown(&1, :brutal_kill))
      end
    end
  end

  test "legacy aggregate attachment no-op preserves the existing file and cleans staged files" do
    with_storage(fn ->
      {note, input} = attachment_note()
      original = hd(note.attachments)
      files = Repo.aggregate(StorageFile, :count)

      assert {:ok, same} = GaoNote.update_note(note, %{attachments: [input]}, nil)
      assert same.revision == note.revision
      assert same.updated_at == note.updated_at
      assert hd(same.attachments).storage_file_id == original.storage_file_id
      assert hd(same.attachments).updated_at == original.updated_at
      assert Repo.aggregate(StorageFile, :count) == files
      refute purge_scheduled?(original.storage_file_id)

      assert {:ok, changed} =
               GaoNote.update_note(same, %{title: "Changed", attachments: [input]}, nil)

      assert changed.revision == note.revision + 1
      assert hd(changed.attachments).storage_file_id == original.storage_file_id
      assert Repo.aggregate(StorageFile, :count) == files
      refute purge_scheduled?(original.storage_file_id)
    end)
  end

  test "old attachment read failure rolls back fields labels and revisions and cleans staging" do
    with_storage(fn ->
      {note, input} = attachment_note()
      original = hd(note.attachments)
      files = Repo.aggregate(StorageFile, :count)
      Application.put_env(:gsmlg_gao_note, :shared_writer_read_failure, true)

      assert {:error, _reason} =
               GaoNote.update_note(
                 note,
                 %{title: "Must roll back", labels: ["new=value"], attachments: [input]},
                 nil
               )

      assert {:error, _reason} =
               Compat.patch_note(
                 note.id,
                 note.revision,
                 %{
                   title: "Must also roll back",
                   labels: [{"new", "value"}],
                   attachments: [input]
                 },
                 nil
               )

      persisted = Compat.get_note(note.id)
      assert persisted.title == note.title
      assert persisted.revision == note.revision
      assert persisted.updated_at == note.updated_at
      assert Catalog.pairs(persisted) == []
      assert hd(persisted.attachments).storage_file_id == original.storage_file_id
      assert Repo.get(StorageFile, original.storage_file_id).status == "active"
      assert Repo.aggregate(StorageFile, :count) == files
      refute purge_scheduled?(original.storage_file_id)
      assert Repo.get_by(LabelSetting, name: "new") == nil
    end)
  end

  test "legacy catalog rename advances active and deleted notes only on actual label changes" do
    {setting, active, deleted, unrelated} = catalog_notes()

    assert {:ok, renamed} = GaoNote.update_label_setting(setting, %{name: "renamed"}, nil)
    assert Repo.get(Note, active.id).revision == active.revision + 1
    assert Repo.get(Note, deleted.id).revision == deleted.revision + 1
    assert Repo.get(Note, unrelated.id).revision == unrelated.revision
    assert Catalog.pairs(Compat.get_note(active.id)) == [{"renamed", "value"}]

    assert {:error, {:revision_conflict, %{current_revision: 2}}} =
             Compat.patch_note(active.id, active.revision, %{title: "stale"}, nil)

    assert {:error, {:revision_conflict, %{current_revision: 3}}} =
             Compat.restore_note(deleted.id, deleted.revision, nil)

    assert {:ok, _} =
             GaoNote.update_label_setting(renamed, %{name: "renamed", description: "edited"}, nil)

    assert Repo.get(Note, active.id).revision == active.revision + 1
    assert Repo.get(Note, deleted.id).revision == deleted.revision + 1
  end

  test "legacy catalog deletion advances affected revisions and keeps category protection" do
    {setting, active, deleted, unrelated} = catalog_notes()

    assert {:ok, _} = GaoNote.delete_label_setting(setting, nil)
    assert Repo.get(Note, active.id).revision == active.revision + 1
    assert Repo.get(Note, deleted.id).revision == deleted.revision + 1
    assert Repo.get(Note, unrelated.id).revision == unrelated.revision
    assert Catalog.pairs(Compat.get_note(active.id)) == []
    assert Repo.preload(Repo.get!(Note, deleted.id), :labels).labels == []

    protected = save([{"protected", "value"}])
    setting = Repo.get_by!(LabelSetting, name: "protected")

    assert {:ok, _} =
             %CategorySetting{}
             |> CategorySetting.changeset(%{label_setting_id: setting.id, position: 0})
             |> Repo.insert()

    assert {:error, {:category_label_in_use, _}} = GaoNote.delete_label_setting(setting, nil)
    assert Repo.get(Note, protected.id).revision == protected.revision
    assert Catalog.pairs(Compat.get_note(protected.id)) == [{"protected", "value"}]
  end

  defp save(labels) do
    {:ok, note} =
      Compat.save_note(%{title: "Title", content: "Body", labels: labels, attachments: []}, nil)

    note
  end

  defp mutate_catalog(:rename, setting, key),
    do: GaoNote.update_label_setting(setting, %{name: key <> "-renamed"}, nil)

  defp mutate_catalog(:delete, setting, _key), do: GaoNote.delete_label_setting(setting, nil)

  defp mutate_missing_catalog(:update, key),
    do: Compat.update_label_key(key, %{description: "after deletion"}, nil)

  defp mutate_missing_catalog(:delete, key), do: Compat.delete_label_key(key, nil)

  defp assert_insertion_outcome(:rename, unrelated, key, result) do
    assert {:ok, %{revision: 2}} = result
    note = Compat.get_note(unrelated.id)
    assert note.revision == 2
    assert Catalog.pairs(note) == [{key <> "-renamed", "added"}]
  end

  defp assert_insertion_outcome(:delete, unrelated, _key, result) do
    assert {:error, %Ecto.Changeset{}} = result
    note = Compat.get_note(unrelated.id)
    assert note.revision == 1
    assert Catalog.pairs(note) == []
  end

  defp catalog_notes do
    active = save([{"shared", "value"}])
    deleted = save([{"shared", "trash"}])
    {:ok, deleted} = GaoNote.delete_note(deleted, nil)
    unrelated = save([])
    {Repo.get_by!(LabelSetting, name: "shared"), active, deleted, unrelated}
  end

  defp attachment_note do
    input = %{
      id: Ecto.UUID.generate(),
      path: "./doc.txt",
      mime: "text/plain",
      description: "",
      content: "same"
    }

    {:ok, note} =
      GaoNote.create_note(%{title: "Title", content: "Body", attachments: [input]}, nil)

    {note, input}
  end

  defp purge_scheduled?(id) do
    Repo.exists?(from(job in Oban.Job, where: fragment("?->>'storage_file_id'", job.args) == ^id))
  end

  defp blocked?(pid, deadline) do
    blocked =
      outside_sandbox(fn ->
        %{rows: [[blocked]]} =
          SQL.query!(
            Repo,
            "SELECT wait_event_type = 'Lock' FROM pg_stat_activity WHERE pid = $1",
            [pid]
          )

        blocked
      end)

    cond do
      blocked ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        blocked?(pid, deadline)
    end
  end

  defp outside_sandbox(operation) do
    Task.async(fn -> with_connection(operation) end)
    |> Task.await(10_000)
  end

  defp with_connection(operation) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      operation.()
    after
      Sandbox.checkin(Repo)
    end
  end

  defmodule StorageStub do
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    put "/*path" do
      {:ok, _, conn} = Plug.Conn.read_body(conn)
      send_resp(conn, 200, "")
    end

    get "/*path" do
      if Application.get_env(:gsmlg_gao_note, :shared_writer_read_failure),
        do: send_resp(conn, 503, "unavailable"),
        else: send_resp(conn, 200, "same")
    end

    delete("/*path", do: send_resp(conn, 204, ""))
  end

  defp with_storage(fun) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    {:ok, stub} = Bandit.start_link(plug: StorageStub, port: port, startup_log: false)

    values = %{
      allowed_types: %{"gao_note_attachment" => :any},
      s3_access_key_id: "test",
      s3_bucket: "test",
      s3_endpoint: "http://127.0.0.1:#{port}",
      s3_secret_access_key: "test"
    }

    previous =
      Map.new(values, fn {key, _} -> {key, Application.fetch_env(:gsmlg_storage, key)} end)

    Enum.each(values, fn {key, value} -> Application.put_env(:gsmlg_storage, key, value) end)

    try do
      Oban.Testing.with_testing_mode(:manual, fun)
    after
      Application.delete_env(:gsmlg_gao_note, :shared_writer_read_failure)

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)

      GenServer.stop(stub)
    end
  end
end
