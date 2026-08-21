defmodule GSMLG.GaoNote.BatchActionsTest do
  use GSMLG.GaoNote.DataCase, async: false
  use Oban.Testing, repo: GSMLG.Repo

  alias GSMLG.GaoNote

  alias GSMLG.GaoNote.{
    Attachment,
    CategorySetting,
    Label,
    LabelSetting,
    Log,
    Note
  }

  alias GSMLG.Storage.StorageFile

  setup do
    Repo.delete_all(CategorySetting)
    Repo.delete_all(Log)
    Repo.delete_all(Attachment)
    Repo.delete_all(Label)
    Repo.delete_all(LabelSetting)
    Repo.delete_all(Note)
    Repo.delete_all(StorageFile)
    :ok
  end

  describe "batch_mutate_note_labels/3 add" do
    test "adds missing labels, leaves exact values unchanged, and audits only changed notes" do
      project = label_setting_fixture(%{name: "project"})
      missing = note_fixture(%{title: "Missing project"})
      exact = note_fixture(%{title: "Exact project", labels: ["project=alpha"]})
      clear_logs()

      assert {:ok, %{selected: 2, matched: 2, changed: 1, unchanged: 1}} =
               GaoNote.batch_mutate_note_labels(
                 [exact.id, missing.id],
                 {:add, %{label_setting_id: project.id, value: " alpha "}},
                 actor()
               )

      assert %{"project" => "alpha"} = labels_for(missing.id)
      assert %{"project" => "alpha"} = labels_for(exact.id)

      missing_id = missing.id

      assert [
               %Log{
                 action: "update",
                 entity_type: "note",
                 entity_id: ^missing_id,
                 note_id: ^missing_id,
                 actor_id: "batch-actor",
                 source: "mcp",
                 details: %{
                   "title" => "Missing project",
                   "fields" => ["labels"],
                   "batch" => %{"operation" => "add"}
                 }
               }
             ] = logs()
    end

    test "one conflicting value rolls back every selected note and every audit" do
      project = label_setting_fixture(%{name: "project"})
      missing = note_fixture(%{title: "Would change"})
      conflict = note_fixture(%{title: "Conflicts", labels: ["project=beta"]})
      clear_logs()
      conflict_id = conflict.id

      assert {:error,
              {:label_conflict,
               %{operation: :add, label_setting_id: project_id, note_ids: [^conflict_id]}}} =
               GaoNote.batch_mutate_note_labels(
                 [missing.id, conflict.id],
                 {:add, %{label_setting_id: project.id, value: "alpha"}},
                 actor()
               )

      assert project_id == project.id
      assert labels_for(missing.id) == %{}
      assert %{"project" => "beta"} = labels_for(conflict.id)
      assert logs() == []
    end
  end

  describe "batch_mutate_note_labels/3 edit" do
    test "uses an exact selector, changes the setting name, and preserves other labels" do
      status = label_setting_fixture(%{name: "status"})
      type = label_setting_fixture(%{name: "type"})
      _project = label_setting_fixture(%{name: "project"})

      draft =
        note_fixture(%{
          title: "Draft",
          labels: ["status=draft", "project=umbrella"]
        })

      published =
        note_fixture(%{
          title: "Published",
          labels: ["status=published", "project=umbrella"]
        })

      unmatched = note_fixture(%{title: "No status", labels: ["project=umbrella"]})
      clear_logs()

      assert {:ok, %{selected: 3, matched: 1, changed: 1, unchanged: 2}} =
               GaoNote.batch_mutate_note_labels(
                 [published.id, unmatched.id, draft.id],
                 {:edit,
                  %{
                    match: %{label_setting_id: status.id, value: {:exact, " draft "}},
                    replacement: %{label_setting_id: type.id, value: "article"}
                  }},
                 actor()
               )

      assert %{"project" => "umbrella", "type" => "article"} = labels_for(draft.id)

      assert %{"project" => "umbrella", "status" => "published"} =
               labels_for(published.id)

      assert %{"project" => "umbrella"} = labels_for(unmatched.id)

      draft_id = draft.id

      assert [%Log{entity_id: ^draft_id, details: %{"batch" => %{"operation" => "edit"}}}] =
               logs()
    end

    test "edits values in place with an any-value selector" do
      status = label_setting_fixture(%{name: "status"})
      draft = note_fixture(%{labels: ["status=draft"]})
      already_done = note_fixture(%{labels: ["status=done"]})
      clear_logs()

      assert {:ok, %{selected: 2, matched: 2, changed: 1, unchanged: 1}} =
               GaoNote.batch_mutate_note_labels(
                 [draft.id, already_done.id],
                 {:edit,
                  %{
                    match: %{label_setting_id: status.id, value: :any},
                    replacement: %{label_setting_id: status.id, value: " done "}
                  }},
                 actor()
               )

      assert %{"status" => "done"} = labels_for(draft.id)
      assert %{"status" => "done"} = labels_for(already_done.id)
      draft_id = draft.id
      assert [%Log{entity_id: ^draft_id}] = logs()
    end

    test "a replacement-setting collision rolls back all edits" do
      status = label_setting_fixture(%{name: "status"})
      type = label_setting_fixture(%{name: "type"})
      colliding = note_fixture(%{labels: ["status=draft", "type=existing"]})
      would_change = note_fixture(%{labels: ["status=draft"]})
      clear_logs()
      colliding_id = colliding.id

      assert {:error,
              {:label_conflict,
               %{operation: :edit, label_setting_id: type_id, note_ids: [^colliding_id]}}} =
               GaoNote.batch_mutate_note_labels(
                 [would_change.id, colliding.id],
                 {:edit,
                  %{
                    match: %{label_setting_id: status.id, value: :any},
                    replacement: %{label_setting_id: type.id, value: "article"}
                  }},
                 actor()
               )

      assert type_id == type.id
      assert %{"status" => "draft", "type" => "existing"} = labels_for(colliding.id)
      assert %{"status" => "draft"} = labels_for(would_change.id)
      assert logs() == []
    end
  end

  describe "batch_mutate_note_labels/3 delete" do
    test "deletes every selected value with an any-value selector" do
      status = label_setting_fixture(%{name: "status"})
      labeled = note_fixture(%{labels: ["status=draft"]})
      unmatched = note_fixture()
      clear_logs()

      assert {:ok, %{selected: 2, matched: 1, changed: 1, unchanged: 1}} =
               GaoNote.batch_mutate_note_labels(
                 [labeled.id, unmatched.id],
                 {:delete, %{match: %{label_setting_id: status.id, value: :any}}},
                 actor()
               )

      assert labels_for(labeled.id) == %{}
      assert labels_for(unmatched.id) == %{}
      labeled_id = labeled.id
      assert [%Log{entity_id: ^labeled_id}] = logs()
    end

    test "deletes only an exact normalized value" do
      status = label_setting_fixture(%{name: "status"})
      draft = note_fixture(%{labels: ["status=draft"]})
      published = note_fixture(%{labels: ["status=published"]})
      clear_logs()

      assert {:ok, %{selected: 2, matched: 1, changed: 1, unchanged: 1}} =
               GaoNote.batch_mutate_note_labels(
                 [published.id, draft.id],
                 {:delete, %{match: %{label_setting_id: status.id, value: {:exact, " draft "}}}},
                 actor()
               )

      assert labels_for(draft.id) == %{}
      assert %{"status" => "published"} = labels_for(published.id)
      draft_id = draft.id

      assert [%Log{entity_id: ^draft_id, details: %{"batch" => %{"operation" => "delete"}}}] =
               logs()
    end

    test "zero-match edit and delete are successful unaudited no-ops" do
      status = label_setting_fixture(%{name: "status"})
      type = label_setting_fixture(%{name: "type"})
      note = note_fixture(%{labels: ["type=article"]})
      clear_logs()

      assert {:ok, %{selected: 1, matched: 0, changed: 0, unchanged: 1}} =
               GaoNote.batch_mutate_note_labels(
                 [note.id],
                 {:edit,
                  %{
                    match: %{label_setting_id: status.id, value: :any},
                    replacement: %{label_setting_id: type.id, value: "other"}
                  }},
                 actor()
               )

      assert {:ok, %{selected: 1, matched: 0, changed: 0, unchanged: 1}} =
               GaoNote.batch_mutate_note_labels(
                 [note.id],
                 {:delete, %{match: %{label_setting_id: status.id, value: :any}}},
                 actor()
               )

      assert %{"type" => "article"} = labels_for(note.id)
      assert logs() == []
    end
  end

  describe "batch_mutate_note_labels/3 validation" do
    test "rejects invalid typed add, replacement, and exact-match values" do
      year = label_setting_fixture(%{name: "year", value_type: "year"})
      status = label_setting_fixture(%{name: "status"})
      note = note_fixture(%{labels: ["status=draft"]})
      clear_logs()
      year_id = year.id

      assert {:error,
              {:invalid_label_value, %{label_setting_id: ^year_id, errors: ["must be YYYY"]}}} =
               GaoNote.batch_mutate_note_labels(
                 [note.id],
                 {:add, %{label_setting_id: year.id, value: "August"}},
                 actor()
               )

      assert {:error,
              {:invalid_label_value, %{label_setting_id: ^year_id, errors: ["must be YYYY"]}}} =
               GaoNote.batch_mutate_note_labels(
                 [note.id],
                 {:edit,
                  %{
                    match: %{label_setting_id: status.id, value: :any},
                    replacement: %{label_setting_id: year.id, value: "20x6"}
                  }},
                 actor()
               )

      assert {:error,
              {:invalid_label_value, %{label_setting_id: ^year_id, errors: ["must be YYYY"]}}} =
               GaoNote.batch_mutate_note_labels(
                 [note.id],
                 {:delete, %{match: %{label_setting_id: year.id, value: {:exact, "invalid"}}}},
                 actor()
               )

      assert %{"status" => "draft"} = labels_for(note.id)
      assert logs() == []
    end

    test "rejects missing referenced label settings" do
      missing_id = Ecto.UUID.generate()
      note = note_fixture()
      clear_logs()

      assert {:error, {:label_settings_unavailable, %{ids: [^missing_id]}}} =
               GaoNote.batch_mutate_note_labels(
                 [note.id],
                 {:add, %{label_setting_id: missing_id, value: "value"}},
                 actor()
               )

      assert labels_for(note.id) == %{}
      assert logs() == []
    end

    test "rejects malformed operation shapes without dynamically interpreting keys" do
      note = note_fixture()
      clear_logs()

      for operation <- [
            :add,
            {:add, %{"label_setting_id" => Ecto.UUID.generate(), "value" => "x"}},
            {:rename, %{}},
            {:delete, %{match: %{label_setting_id: Ecto.UUID.generate(), value: :all}}}
          ] do
        assert {:error, {:invalid_operation, %{code: :unsupported_shape}}} =
                 GaoNote.batch_mutate_note_labels([note.id], operation, actor())
      end

      assert logs() == []
    end

    test "rejects unavailable selected notes atomically" do
      project = label_setting_fixture(%{name: "project"})
      active = note_fixture()
      deleted = note_fixture()
      assert {:ok, %Note{}} = GaoNote.delete_note(deleted, actor())
      stale_id = Ecto.UUID.generate()
      clear_logs()
      missing_ids = Enum.sort([deleted.id, stale_id])

      assert {:error, {:notes_unavailable, %{state: :active, ids: ^missing_ids}}} =
               GaoNote.batch_mutate_note_labels(
                 [active.id, stale_id, deleted.id],
                 {:add, %{label_setting_id: project.id, value: "umbrella"}},
                 actor()
               )

      assert labels_for(active.id) == %{}
      assert logs() == []
    end

    test "rejects invalid note selections with distinct structured errors" do
      project = label_setting_fixture(%{name: "project"})
      note = note_fixture()
      operation = {:add, %{label_setting_id: project.id, value: "umbrella"}}
      clear_logs()

      assert {:error, {:invalid_selection, %{code: :must_be_a_list}}} =
               GaoNote.batch_mutate_note_labels(note.id, operation, actor())

      assert {:error, {:invalid_selection, %{code: :empty}}} =
               GaoNote.batch_mutate_note_labels([], operation, actor())

      assert {:error, {:invalid_selection, %{code: :duplicate, id: duplicate_id}}} =
               GaoNote.batch_mutate_note_labels([note.id, note.id], operation, actor())

      assert duplicate_id == note.id

      assert {:error, {:invalid_selection, %{code: :invalid_id, id: "not-a-uuid"}}} =
               GaoNote.batch_mutate_note_labels(["not-a-uuid"], operation, actor())

      too_many_ids = Enum.map(1..101, fn _index -> Ecto.UUID.generate() end)

      assert {:error, {:invalid_selection, %{code: :too_many, limit: 100}}} =
               GaoNote.batch_mutate_note_labels(too_many_ids, operation, actor())

      assert logs() == []
    end
  end

  test "preserves title, content, attachments, and unmentioned labels" do
    status = label_setting_fixture(%{name: "status"})
    project = label_setting_fixture(%{name: "project"})

    note =
      note_fixture(%{
        title: "Preserved title",
        content: "Preserved content",
        labels: ["status=draft", "project=umbrella"]
      })

    attachment = attachment_fixture(note)
    clear_logs()

    assert {:ok, %{selected: 1, matched: 1, changed: 1, unchanged: 0}} =
             GaoNote.batch_mutate_note_labels(
               [note.id],
               {:edit,
                %{
                  match: %{label_setting_id: status.id, value: :any},
                  replacement: %{label_setting_id: status.id, value: "published"}
                }},
               actor()
             )

    attachment_id = attachment.id
    storage_file_id = attachment.storage_file_id

    assert %Note{
             title: "Preserved title",
             content: "Preserved content",
             attachments: [
               %Attachment{id: ^attachment_id, storage_file_id: ^storage_file_id}
             ]
           } = GaoNote.get_note(note.id)

    assert %{"project" => "umbrella", "status" => "published"} = labels_for(note.id)
    assert %LabelSetting{} = GaoNote.get_label_setting(project.id)
  end

  test "an outer rollback reverts label writes and batch audits together" do
    project = label_setting_fixture(%{name: "project"})
    note = note_fixture()
    clear_logs()

    assert {:error, :rollback_proof} =
             Repo.transaction(fn ->
               assert {:ok, %{changed: 1}} =
                        GaoNote.batch_mutate_note_labels(
                          [note.id],
                          {:add, %{label_setting_id: project.id, value: "umbrella"}},
                          actor()
                        )

               assert [_log] = logs()
               Repo.rollback(:rollback_proof)
             end)

    assert labels_for(note.id) == %{}
    assert logs() == []
  end

  defp label_setting_fixture(attrs) do
    assert {:ok, label_setting} = GaoNote.create_label_setting(attrs, actor())
    clear_logs()
    label_setting
  end

  defp note_fixture(attrs \\ %{}) do
    attrs =
      Map.merge(
        %{title: "Batch note #{System.unique_integer([:positive])}", content: "Body"},
        attrs
      )

    assert {:ok, note} = GaoNote.create_note(attrs, actor())
    clear_logs()
    note
  end

  defp attachment_fixture(note) do
    suffix = System.unique_integer([:positive])

    storage_file =
      %StorageFile{}
      |> StorageFile.changeset(%{
        tenant: "gao_note",
        type: "gao_note_attachment",
        filename: "preserved.txt",
        s3_key: "batch-actions/#{suffix}/preserved.txt",
        content_type: "text/plain",
        size: 9,
        checksum: "checksum-#{suffix}",
        uploaded_by: "batch-actor"
      })
      |> Repo.insert!()

    %Attachment{}
    |> Attachment.changeset(%{
      id: "preserved-#{suffix}",
      note_id: note.id,
      storage_file_id: storage_file.id,
      path: "preserved.txt",
      mime: "text/plain",
      description: "Preserved"
    })
    |> Repo.insert!()
  end

  defp labels_for(note_id) do
    note_id
    |> GaoNote.get_note!()
    |> Map.fetch!(:labels)
    |> Map.new(fn label -> {label.label_setting.name, label.value} end)
  end

  defp logs do
    Log
    |> order_by([log], asc: log.entity_id)
    |> Repo.all()
  end

  defp clear_logs, do: Repo.delete_all(Log)

  defp actor do
    %{id: "batch-actor", source: "mcp"}
  end
end

defmodule GSMLG.GaoNote.BatchActionsDatabaseTest do
  use GSMLG.GaoNote.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{Label, LabelSetting, Log, Note}

  test "an audit constraint failure returns a domain error and rolls back label writes" do
    fixture = prepare_fixture("audit-failure")
    constraint = "gao_note_batch_audit_reject_#{fixture.suffix}"

    on_exit(fn ->
      outside_sandbox(fn ->
        SQL.query!(
          Repo,
          "ALTER TABLE gao_note_logs DROP CONSTRAINT IF EXISTS #{constraint}",
          []
        )

        cleanup_fixture(fixture)
      end)
    end)

    outside_sandbox(fn ->
      SQL.query!(
        Repo,
        """
        ALTER TABLE gao_note_logs
        ADD CONSTRAINT #{constraint}
        CHECK (NOT (details ? 'batch'))
        """,
        []
      )
    end)

    note_id = fixture.first.id
    second_note_id = fixture.second.id

    assert {:error,
            {:batch_audit_failed,
             %{note_id: ^note_id, reason: %{type: :constraint, constraint: ^constraint}}}} =
             outside_sandbox(fn ->
               GaoNote.batch_mutate_note_labels(
                 [fixture.first.id],
                 {:edit,
                  %{
                    match: %{label_setting_id: fixture.setting.id, value: :any},
                    replacement: %{label_setting_id: fixture.setting.id, value: "updated"}
                  }},
                 actor()
               )
             end)

    assert %{^note_id => "initial", ^second_note_id => "initial"} =
             Map.new(persisted_values(fixture))

    assert [] = persisted_logs(fixture)
  end

  test "overlapping inverse-order batches use separate connections without deadlocking" do
    fixture = prepare_fixture("concurrency")
    function = "gao_note_batch_delay_#{fixture.suffix}"
    trigger = "gao_note_batch_delay_trigger_#{fixture.suffix}"

    on_exit(fn ->
      outside_sandbox(fn ->
        drop_delay_trigger(trigger, function)
        cleanup_fixture(fixture)
      end)
    end)

    install_delay_trigger(trigger, function)

    first_operation = edit_operation(fixture.setting.id, "first")
    second_operation = edit_operation(fixture.setting.id, "second")

    {first_owner, first_batch} =
      start_allowed_batch(
        [fixture.first.id, fixture.second.id],
        first_operation
      )

    {second_owner, second_batch} =
      start_allowed_batch(
        [fixture.second.id, fixture.first.id],
        second_operation
      )

    results =
      try do
        send(first_batch.pid, :run)
        send(second_batch.pid, :run)
        Task.await_many([first_batch, second_batch], 5_000)
      after
        stop_connection_owner(first_owner)
        stop_connection_owner(second_owner)
      end

    assert [
             {:ok, %{selected: 2, matched: 2, changed: 2, unchanged: 0}},
             {:ok, %{selected: 2, matched: 2, changed: 2, unchanged: 0}}
           ] = results

    first_id = fixture.first.id
    second_id = fixture.second.id

    assert persisted_values(fixture) in [
             Enum.sort([{first_id, "first"}, {second_id, "first"}]),
             Enum.sort([{first_id, "second"}, {second_id, "second"}])
           ]
  end

  defp prepare_fixture(prefix) do
    outside_sandbox(fn ->
      suffix = System.unique_integer([:positive])

      assert {:ok, setting} =
               GaoNote.create_label_setting(%{name: "#{prefix}-#{suffix}"}, actor())

      assert {:ok, first} =
               GaoNote.create_note(
                 %{
                   title: "#{prefix} first #{suffix}",
                   content: "Body",
                   labels: ["#{setting.name}=initial"]
                 },
                 actor()
               )

      assert {:ok, second} =
               GaoNote.create_note(
                 %{
                   title: "#{prefix} second #{suffix}",
                   content: "Body",
                   labels: ["#{setting.name}=initial"]
                 },
                 actor()
               )

      note_ids = [first.id, second.id]
      Repo.delete_all(from(log in Log, where: log.note_id in ^note_ids))

      %{suffix: suffix, setting: setting, first: first, second: second}
    end)
  end

  defp cleanup_fixture(fixture) do
    note_ids = [fixture.first.id, fixture.second.id]
    Repo.delete_all(from(log in Log, where: log.note_id in ^note_ids))
    Repo.delete_all(from(label in Label, where: label.note_id in ^note_ids))
    Repo.delete_all(from(note in Note, where: note.id in ^note_ids))
    Repo.delete_all(from(setting in LabelSetting, where: setting.id == ^fixture.setting.id))
  end

  defp persisted_values(fixture) do
    note_ids = [fixture.first.id, fixture.second.id]

    outside_sandbox(fn ->
      Label
      |> where([label], label.note_id in ^note_ids)
      |> order_by([label], asc: label.note_id)
      |> select([label], {label.note_id, label.value})
      |> Repo.all()
    end)
  end

  defp persisted_logs(fixture) do
    note_ids = [fixture.first.id, fixture.second.id]

    outside_sandbox(fn ->
      Log
      |> where([log], log.note_id in ^note_ids)
      |> Repo.all()
    end)
  end

  defp edit_operation(label_setting_id, value) do
    {:edit,
     %{
       match: %{label_setting_id: label_setting_id, value: :any},
       replacement: %{label_setting_id: label_setting_id, value: value}
     }}
  end

  defp install_delay_trigger(trigger, function) do
    outside_sandbox(fn ->
      drop_delay_trigger(trigger, function)

      SQL.query!(
        Repo,
        """
        CREATE FUNCTION #{function}()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $$
        BEGIN
          PERFORM pg_sleep(0.15);
          RETURN NEW;
        END;
        $$;
        """,
        []
      )

      SQL.query!(
        Repo,
        """
        CREATE TRIGGER #{trigger}
        BEFORE UPDATE ON gao_note_labels
        FOR EACH ROW EXECUTE FUNCTION #{function}();
        """,
        []
      )
    end)
  end

  defp drop_delay_trigger(trigger, function) do
    SQL.query!(Repo, "DROP TRIGGER IF EXISTS #{trigger} ON gao_note_labels", [])
    SQL.query!(Repo, "DROP FUNCTION IF EXISTS #{function}()", [])
  end

  defp start_allowed_batch(note_ids, operation) do
    parent = self()

    owner =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)
        send(parent, {:connection_ready, self()})

        receive do
          :stop -> Sandbox.checkin(Repo)
        end
      end)

    assert_receive {:connection_ready, owner_pid}, 2_000
    assert owner_pid == owner.pid

    batch =
      Task.async(fn ->
        receive do
          :run -> GaoNote.batch_mutate_note_labels(note_ids, operation, actor())
        end
      end)

    assert :ok = Sandbox.allow(Repo, owner.pid, batch.pid)
    {owner, batch}
  end

  defp stop_connection_owner(owner) do
    send(owner.pid, :stop)
    assert :ok = Task.await(owner, 2_000)
  end

  defp outside_sandbox(fun) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        fun.()
      after
        Sandbox.checkin(Repo)
      end
    end)
    |> Task.await(10_000)
  end

  defp actor do
    %{id: "batch-database-test", source: "test"}
  end
end
