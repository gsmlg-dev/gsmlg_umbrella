# GaoNote Batch Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add explicit atomic batch label mutation, soft deletion, and Recycle Bin permanent deletion to the native GaoNote admin LiveViews.

**Architecture:** LiveViews own loaded-row selection, previews, modal state, and feedback. A focused `GSMLG.GaoNote.BatchActions` module owns authoritative validation, deterministic locking, mutation, deletion, purge-job scheduling, and per-note auditing, exposed through the existing `GSMLG.GaoNote` context.

**Tech Stack:** Elixir 1.18, Phoenix LiveView, Ecto/PostgreSQL, Oban, phoenix_duskmoon/DuskMoon CSS, Bun tests.

---

## Scope and file map

Create:

- `apps/gsmlg_gao_note/lib/gsmlg/gao_note/label_value.ex` — shared value normalization and type validation.
- `apps/gsmlg_gao_note/lib/gsmlg/gao_note/audit.ex` — shared transactional audit insertion and actor normalization.
- `apps/gsmlg_gao_note/lib/gsmlg/gao_note/batch_actions.ex` — batch locking, mutation, deletion, and purge behavior.
- `apps/gsmlg_gao_note/test/gsmlg/gao_note/label_value_test.exs` — value-validation tests.
- `apps/gsmlg_gao_note/test/gsmlg/gao_note/batch_actions_test.exs` — batch domain tests.
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/batch_selection.ex` — shared pure selection helpers.
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/batch_action_components.ex` — stateless batch toolbars and modals.
- `apps/gsmlg_admin_web/assets/js/hooks/indeterminate_checkbox.js` and `.test.js` — native mixed-checkbox synchronization.
- `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_batch_selection_test.exs` — selection-helper tests.

Modify:

- `apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex` — delegate batch APIs and reuse extracted helpers.
- `apps/gsmlg_admin_web/assets/js/hooks.js` — register the checkbox hook.
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/index.ex` — Notes selection and batch actions.
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/recycle_bin_live/index.ex` — Recycle Bin selection and purge.
- `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs` — connected LiveView tests.

Do not modify routes, migrations, REST/OpenAPI/MCP modules, list limits, single-note contracts, or unrelated untracked API-discovery documents.

`dm_table` accepts only string column headers, so it cannot render the select-all checkbox. Upstream Feature request [duskmoon-dev/phoenix-duskmoon-ui#145](https://github.com/duskmoon-dev/phoenix-duskmoon-ui/issues/145) tracks the missing capability. Use a native semantic table for Notes with this marker immediately above it:

```heex
<%# WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#145 %>
```

## Task 1: Extract shared label validation and audit helpers

**Files:**
- Create: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/label_value.ex`
- Create: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/audit.ex`
- Create: `apps/gsmlg_gao_note/test/gsmlg/gao_note/label_value_test.exs`
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex:9,267,333-344,430,469,723,939-944,1100-1165,1182,1190-1192,1239-1248,1377-1389`

- [ ] **Step 1: Write direct label-value characterization tests**

```elixir
defmodule GSMLG.GaoNote.LabelValueTest do
  use ExUnit.Case, async: true

  alias GSMLG.GaoNote.{LabelSetting, LabelValue}

  test "normalizes and validates typed values" do
    setting = %LabelSetting{id: Ecto.UUID.generate(), value_type: "year-month"}

    assert LabelValue.normalize(nil) == ""
    assert LabelValue.normalize(" 2026-08 ") == "2026-08"
    assert {"valid", []} = LabelValue.classify(setting, "2026-08")
    assert {"invalid", ["must be YYYY-MM"]} = LabelValue.classify(setting, "August")
    assert {:ok, "2026-08"} = LabelValue.validate(setting, " 2026-08 ")

    assert {:error,
            {:invalid_label_value,
             %{label_setting_id: setting.id, errors: ["must be YYYY-MM"]}}} =
             LabelValue.validate(setting, "August")
  end
end
```

- [ ] **Step 2: Run the test and verify the missing-module failure**

```bash
unbuffer mix test apps/gsmlg_gao_note/test/gsmlg/gao_note/label_value_test.exs
```

Expected: FAIL because `GSMLG.GaoNote.LabelValue` is undefined.

- [ ] **Step 3: Implement the shared value module by moving the existing rules intact**

```elixir
defmodule GSMLG.GaoNote.LabelValue do
  @moduledoc false
  alias GSMLG.GaoNote.LabelSetting

  def normalize(nil), do: ""
  def normalize(value) when is_binary(value), do: String.trim(value)
  def normalize(value), do: value |> to_string() |> String.trim()

  def classify(%LabelSetting{value_type: value_type}, value) do
    value = normalize(value)

    case value_type || "text" do
      "text" -> valid()
      "number" -> number(value)
      "version" -> regex(value, ~r/^v?\d+(\.\d+){0,3}([+-][0-9A-Za-z.-]+)?$/, "must be a version")
      "date" -> date(value)
      "date-time" -> datetime(value)
      "time" -> time(value)
      "year" -> regex(value, ~r/^\d{4}$/, "must be YYYY")
      "year-month" -> regex(value, ~r/^\d{4}-(0[1-9]|1[0-2])$/, "must be YYYY-MM")
      "year-season" -> regex(value, ~r/^\d{4}-Q[1-4]$/, "must be YYYY-Q1..YYYY-Q4")
      other -> invalid("unsupported value type #{other}")
    end
  end

  def validate(%LabelSetting{} = setting, value) do
    value = normalize(value)

    case classify(setting, value) do
      {"valid", []} -> {:ok, value}
      {"invalid", errors} ->
        {:error, {:invalid_label_value, %{label_setting_id: setting.id, errors: errors}}}
    end
  end

  defp number(value) do
    case Float.parse(value) do
      {_number, ""} -> valid()
      _other -> invalid("must be a number")
    end
  end

  defp date(value) do
    case Date.from_iso8601(value) do
      {:ok, _date} -> valid()
      {:error, _reason} -> invalid("must be YYYY-MM-DD")
    end
  end

  defp datetime(value) do
    cond do
      match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value)) -> valid()
      match?({:ok, _datetime}, NaiveDateTime.from_iso8601(value)) -> valid()
      true -> invalid("must be ISO8601 date-time")
    end
  end

  defp time(value) do
    case Time.from_iso8601(value) do
      {:ok, _time} -> valid()
      {:error, _reason} -> invalid("must be ISO8601 time")
    end
  end

  defp regex(value, regex, message) do
    if Regex.match?(regex, value), do: valid(), else: invalid(message)
  end

  defp valid, do: {"valid", []}
  defp invalid(message), do: {"invalid", [message]}
end
```

- [ ] **Step 4: Implement shared transactional audit insertion**

```elixir
defmodule GSMLG.GaoNote.Audit do
  @moduledoc false
  alias GSMLG.GaoNote.Log
  alias GSMLG.Repo

  def actor_id(%{id: id}) when is_binary(id), do: id
  def actor_id(%{id: id}), do: to_string(id)
  def actor_id(_actor), do: nil

  def source(%{source: value}) when is_binary(value) and value != "", do: value
  def source(%{"source" => value}) when is_binary(value) and value != "", do: value
  def source(_actor), do: "admin"

  def log(action, entity_type, entity_id, note_id, actor, details) do
    %Log{}
    |> Log.changeset(%{
      action: action,
      entity_type: entity_type,
      entity_id: entity_id,
      note_id: note_id,
      actor_id: actor_id(actor),
      source: source(actor),
      details: details || %{}
    })
    |> Repo.insert()
  end
end
```

Alias both helpers in `GSMLG.GaoNote`. Replace value classification with `LabelValue.classify/2`, normalization with `LabelValue.normalize/1`, and reduce existing private wrappers to:

```elixir
defp actor_id(actor), do: Audit.actor_id(actor)

defp log_action(action, entity_type, entity_id, note_id, actor, details),
  do: Audit.log(action, entity_type, entity_id, note_id, actor, details)
```

Delete only the moved validation and `actor_source/1` helpers. Preserve all existing return shapes.

- [ ] **Step 5: Run focused characterization tests**

```bash
unbuffer mix test \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/label_value_test.exs \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/category_settings_test.exs \
  apps/gsmlg_gao_note/test/gsmlg/gao_note_test.exs:258 \
  apps/gsmlg_gao_note/test/gsmlg/gao_note_test.exs:322 \
  apps/gsmlg_gao_note/test/gsmlg/gao_note_test.exs:359 \
  apps/gsmlg_gao_note/test/gsmlg/gao_note_test.exs:372
```

Expected: PASS with zero failures. Do not run or repair unrelated attachment tests.

- [ ] **Step 6: Commit the extraction**

```bash
git add \
  apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex \
  apps/gsmlg_gao_note/lib/gsmlg/gao_note/audit.ex \
  apps/gsmlg_gao_note/lib/gsmlg/gao_note/label_value.ex \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/label_value_test.exs
git commit -m "refactor(gao-note): share label validation and audit helpers"
```

## Task 2: Implement atomic batch label mutations

**Files:**
- Create: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/batch_actions.ex`
- Create: `apps/gsmlg_gao_note/test/gsmlg/gao_note/batch_actions_test.exs`
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex:66-86`

- [ ] **Step 1: Write failing Add tests**

Use `GSMLG.GaoNote.DataCase`, `async: false`, and `Oban.Testing`. In setup clear `Attachment`, `Log`, `Label`, `LabelSetting`, `Note`, and `StorageFile` in foreign-key-safe order. Build notes through `GaoNote.create_note/2`, then clear their create logs.

```elixir
test "adds missing labels and leaves exact labels unchanged" do
  setting = label_setting("project")
  missing = note("Missing", [])
  exact = note("Exact", ["project=alpha"])

  assert {:ok, %{selected: 2, matched: 2, changed: 1, unchanged: 1}} =
           GaoNote.batch_mutate_note_labels(
             [missing.id, exact.id],
             {:add, %{label_setting_id: setting.id, value: "alpha"}},
             actor()
           )

  assert labels(missing.id) == [{"project", "alpha"}]
  assert labels(exact.id) == [{"project", "alpha"}]
  assert [%Log{action: "update", actor_id: "batch-actor"}] = logs(missing.id)
  assert logs(exact.id) == []
end

test "rolls back when one selected note has another value" do
  setting = label_setting("project")
  missing = note("Missing", [])
  conflicting = note("Conflicting", ["project=beta"])

  assert {:error,
          {:label_conflict,
           %{operation: :add, label_setting_id: setting.id, note_ids: [conflicting.id]}}} =
           GaoNote.batch_mutate_note_labels(
             [missing.id, conflicting.id],
             {:add, %{label_setting_id: setting.id, value: "alpha"}},
             actor()
           )

  assert labels(missing.id) == []
  assert labels(conflicting.id) == [{"project", "beta"}]
  assert logs(missing.id) == []
end
```

Define the test helpers in the same module:

```elixir
defp actor, do: %{id: "batch-actor"}

defp label_setting(name, attrs \\ %{}) do
  {:ok, setting} = GaoNote.create_label_setting(Map.merge(%{name: name}, attrs))
  setting
end

defp note(title, labels) do
  {:ok, note} = GaoNote.create_note(%{title: title, content: "content", labels: labels}, actor())
  Repo.delete_all(from(log in Log, where: log.note_id == ^note.id))
  note
end

defp labels(note_id) do
  GaoNote.get_note(note_id).labels
  |> Enum.map(&{&1.label_setting.name, &1.value})
  |> Enum.sort()
end

defp logs(note_id), do: GaoNote.list_logs(entity_type: "note", note_id: note_id)
```

- [ ] **Step 2: Run and verify the undefined API failure**

```bash
unbuffer mix test apps/gsmlg_gao_note/test/gsmlg/gao_note/batch_actions_test.exs
```

Expected: FAIL because `batch_mutate_note_labels/3` is undefined.

- [ ] **Step 3: Add context delegates and the transaction shell**

```elixir
def batch_mutate_note_labels(note_ids, operation, actor),
  do: BatchActions.mutate_note_labels(note_ids, operation, actor)

def batch_delete_notes(note_ids, actor),
  do: BatchActions.delete_notes(note_ids, actor)

def batch_permanently_delete_notes(note_ids, actor),
  do: BatchActions.permanently_delete_notes(note_ids, actor)
```

In `BatchActions`, normalize 1..100 unique UUIDs and sort before locking. Return structured selection errors:

```elixir
defmodule GSMLG.GaoNote.BatchActions do
  @moduledoc false

  import Ecto.Query, warn: false

  alias GSMLG.GaoNote.{Attachments, Audit, Label, LabelSetting, LabelValue, Note}
  alias GSMLG.Repo

  @active_limit 100
  @deleted_limit 200
end
```

Add the public functions and private helpers inside this module body.

```elixir
{:batch_selection, %{code: :empty}}
{:batch_selection, %{code: :too_many, limit: 100}}
{:batch_selection, %{code: :duplicate}}
{:batch_selection, %{code: :invalid_id, id: submitted_id}}
```

Wrap work with:

```elixir
defp transact(fun) do
  Repo.transaction(fn ->
    case fun.() do
      {:ok, result} -> result
      {:error, reason} -> Repo.rollback(reason)
    end
  end)
  |> case do
    {:ok, result} -> {:ok, result}
    {:error, reason} -> {:error, reason}
  end
end
```

- [ ] **Step 4: Implement the locked Add pipeline**

```elixir
defp mutate_locked_labels(ids, operation, actor) do
  with {:ok, operation} <- normalize_operation(operation),
       {:ok, settings} <- lock_settings(operation),
       {:ok, notes} <- lock_notes(ids, :active),
       labels <- lock_labels(ids),
       {:ok, plan} <- plan_label_mutation(notes, labels, operation, settings),
       {:ok, changed_notes} <- apply_label_plan(plan),
       :ok <- audit_label_changes(changed_notes, operation, actor) do
    {:ok, result_summary(notes, plan, changed_notes)}
  end
end
```

Required helper behavior:

- `normalize_operation/1` accepts only the three approved tagged shapes.
- `lock_settings/1` orders referenced settings by ID with `FOR SHARE`, verifies all exist, and validates target/exact values with `LabelValue.validate/2`.
- `lock_notes/2` orders by ID with `FOR UPDATE` and returns `{:notes_unavailable, %{state: :active, ids: missing_ids}}` when counts differ.
- `lock_labels/1` orders by `note_id` and `label_setting_id` with `FOR UPDATE` and groups by note ID.
- Add emits insert, unchanged, or a complete conflict list before writing.
- Writes use `Label.changeset/2` with normalized value, `status: "valid"`, and `errors: []`.
- Each changed note gets `Audit.log/6` action `"update"`, fields `["labels"]`, and `%{"batch" => %{"operation" => "add"}}`.

- [ ] **Step 5: Add Edit/Delete tests and implementation**

```elixir
test "edits only exact source matches and may change the label name" do
  source = label_setting("type")
  target = label_setting("category")
  skill = note("Skill", ["type=skill", "project=alpha"])
  agent = note("Agent", ["type=agent", "project=beta"])

  operation =
    {:edit,
     %{
       match: %{label_setting_id: source.id, value: {:exact, "skill"}},
       replacement: %{label_setting_id: target.id, value: "knowledge"}
     }}

  assert {:ok, %{selected: 2, matched: 1, changed: 1, unchanged: 1}} =
           GaoNote.batch_mutate_note_labels([skill.id, agent.id], operation, actor())

  assert labels(skill.id) == [{"category", "knowledge"}, {"project", "alpha"}]
  assert labels(agent.id) == [{"project", "beta"}, {"type", "agent"}]
end

test "returns a zero-match Delete as an unaudited no-op" do
  source = label_setting("type")
  selected = note("No Type", ["project=alpha"])

  assert {:ok, %{selected: 1, matched: 0, changed: 0, unchanged: 1}} =
           GaoNote.batch_mutate_note_labels(
             [selected.id],
             {:delete, %{match: %{label_setting_id: source.id, value: :any}}},
             actor()
           )

  assert logs(selected.id) == []
end
```

Add separate cases for value-only Edit, any-value Edit, replacement-name collision rollback, name Delete, exact Delete, invalid typed values, missing settings, stale notes, empty/duplicate/invalid IDs, the 100-ID limit, unchanged-note auditing, and preservation of title, content, attachments, and unmentioned labels.

Match only with explicit tags:

```elixir
defp matches?(%Label{} = label, %{label_setting_id: id, value: :any}),
  do: label.label_setting_id == id

defp matches?(%Label{} = label, %{label_setting_id: id, value: {:exact, value}}),
  do: label.label_setting_id == id and label.value == value
```

Return Edit collisions as `{:label_conflict, %{operation: :edit, label_setting_id: replacement_id, note_ids: sorted_ids}}`. Delete only matched label rows. `matched` counts notes, not rows.

- [ ] **Step 6: Run the full batch label test file**

```bash
unbuffer mix test apps/gsmlg_gao_note/test/gsmlg/gao_note/batch_actions_test.exs
```

Expected: PASS with zero failures.

- [ ] **Step 7: Commit atomic label mutations**

```bash
git add \
  apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex \
  apps/gsmlg_gao_note/lib/gsmlg/gao_note/batch_actions.ex \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/batch_actions_test.exs
git commit -m "feat(gao-note): add atomic batch label mutations"
```

## Task 3: Implement atomic soft deletion and permanent purge

**Files:**
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/batch_actions.ex`
- Modify: `apps/gsmlg_gao_note/test/gsmlg/gao_note/batch_actions_test.exs`

- [ ] **Step 1: Write failing soft-delete tests**

```elixir
test "soft-deletes every selected note and audits the actor" do
  first = note("First", [])
  second = note("Second", [])

  assert {:ok, %{selected: 2, deleted: 2}} =
           GaoNote.batch_delete_notes([first.id, second.id], actor())

  assert GaoNote.get_note(first.id) == nil
  assert GaoNote.get_note(second.id) == nil
  assert GaoNote.get_deleted_note(first.id).deleted_at
  assert [%Log{action: "delete", actor_id: "batch-actor"}] = logs(first.id)
  assert [%Log{action: "delete", actor_id: "batch-actor"}] = logs(second.id)
end

test "rolls back when one selected note is no longer active" do
  active = note("Active", [])
  stale = note("Stale", [])
  {:ok, _deleted} = GaoNote.delete_note(stale, actor())
  Repo.delete_all(from(log in Log, where: log.note_id in ^[active.id, stale.id]))

  assert {:error, {:notes_unavailable, %{state: :active, ids: [stale.id]}}} =
           GaoNote.batch_delete_notes([active.id, stale.id], actor())

  assert %Note{} = GaoNote.get_note(active.id)
  assert logs(active.id) == []
end
```

- [ ] **Step 2: Run and verify failure before implementation**

```bash
unbuffer mix test apps/gsmlg_gao_note/test/gsmlg/gao_note/batch_actions_test.exs
```

Expected: the new soft-delete tests fail.

- [ ] **Step 3: Implement active-note soft deletion inside one transaction**

```elixir
def delete_notes(note_ids, actor) do
  with {:ok, ids} <- normalize_ids(note_ids, @active_limit) do
    transact(fn ->
      with {:ok, notes} <- lock_notes(ids, :active),
           deleted_at <- DateTime.utc_now(),
           {:ok, deleted} <- update_deleted_at(notes, deleted_at),
           :ok <- audit_deletions(deleted, "delete", actor, %{"deleted_at" => deleted_at}) do
        {:ok, %{selected: length(ids), deleted: length(deleted)}}
      end
    end)
  end
end
```

`update_deleted_at/2` calls `Repo.update/1` per locked note and stops on the first error. `audit_deletions/4` inserts per-note logs in the same transaction and merges `%{"batch" => %{"operation" => "delete"}}` into details.

- [ ] **Step 4: Write failing permanent-purge tests**

Insert valid `StorageFile` and `Attachment` records directly through their changesets, soft-delete the owner, clear its old logs, and use Oban manual mode:

```elixir
test "purges recycled notes and transactionally schedules attachment cleanup" do
  deleted = note("Deleted", []) |> with_attachment() |> soft_delete()
  attachment = hd(deleted.attachments)

  Oban.Testing.with_testing_mode(:manual, fn ->
    assert {:ok, %{selected: 1, purged: 1}} =
             GaoNote.batch_permanently_delete_notes([deleted.id], actor())

    assert GaoNote.get_deleted_note(deleted.id) == nil
    assert_enqueued(
      worker: GSMLG.GaoNote.Workers.StorageFilePurgeWorker,
      args: %{storage_file_id: attachment.storage_file_id}
    )
    assert [%Log{action: "purge", actor_id: "batch-actor"}] = logs(deleted.id)
  end)
end

test "does not enqueue or purge when one selected ID is not recycled" do
  deleted = note("Still Deleted", []) |> with_attachment() |> soft_delete()
  active = note("Active", [])
  storage_file_id = hd(deleted.attachments).storage_file_id

  Oban.Testing.with_testing_mode(:manual, fn ->
    assert {:error, {:notes_unavailable, %{state: :deleted, ids: [active.id]}}} =
             GaoNote.batch_permanently_delete_notes([deleted.id, active.id], actor())

    assert %Note{} = GaoNote.get_deleted_note(deleted.id)
    assert [] = all_enqueued(
      worker: GSMLG.GaoNote.Workers.StorageFilePurgeWorker,
      args: %{storage_file_id: storage_file_id}
    )
  end)
end
```

The fixture uses unique S3 keys and never calls external S3.

Add these helpers and aliases to the batch test module:

```elixir
alias GSMLG.GaoNote.Attachment
alias GSMLG.Storage.StorageFile

defp with_attachment(%Note{} = note) do
  suffix = Ecto.UUID.generate()

  storage_file =
    %StorageFile{}
    |> StorageFile.changeset(%{
      tenant: "gao-note-test",
      type: "gao_note_attachment",
      filename: "#{suffix}.txt",
      s3_key: "gao-note-test/#{suffix}.txt",
      content_type: "text/plain",
      size: 4
    })
    |> Repo.insert!()

  attachment =
    %Attachment{}
    |> Attachment.changeset(%{
      id: "attachment-#{suffix}",
      note_id: note.id,
      storage_file_id: storage_file.id,
      path: "./#{suffix}.txt",
      mime: "text/plain"
    })
    |> Repo.insert!()

  %{note | attachments: [attachment]}
end

defp soft_delete(%Note{} = note) do
  {:ok, _deleted} = GaoNote.delete_note(note, actor())
  Repo.delete_all(from(log in Log, where: log.note_id == ^note.id))
  GaoNote.get_deleted_note(note.id)
end
```

- [ ] **Step 5: Implement permanent purge inside one transaction**

```elixir
def permanently_delete_notes(note_ids, actor) do
  with {:ok, ids} <- normalize_ids(note_ids, @deleted_limit) do
    transact(fn ->
      with {:ok, notes} <- lock_notes(ids, :deleted),
           notes <- Repo.preload(notes, :attachments),
           storage_ids <- attachment_storage_file_ids(notes),
           {:ok, _jobs} <- Attachments.schedule_purges(storage_ids),
           {:ok, deleted} <- delete_locked_notes(notes),
           :ok <- audit_deletions(deleted, "purge", actor, %{}) do
        {:ok, %{selected: length(ids), purged: length(deleted)}}
      end
    end)
  end
end
```

Use limit 200 for deleted notes. `lock_notes/2` filters `is_nil(deleted_at)` for active and `not is_nil(deleted_at)` for deleted notes. Deduplicate attachment storage IDs. `delete_locked_notes/1` uses `Repo.delete/1` per note. Purge logs merge `%{"batch" => %{"operation" => "purge"}}`.

- [ ] **Step 6: Add deterministic overlapping-selection coverage**

Use two sandbox-authorized tasks with reversed input order. Assert neither returns a PostgreSQL deadlock exception; each must return success or a structured stale/conflict result. The implementation sorts IDs before every `FOR UPDATE` query.

- [ ] **Step 7: Run the focused domain suite**

```bash
unbuffer mix test \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/label_value_test.exs \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/batch_actions_test.exs
```

Expected: PASS with zero failures.

- [ ] **Step 8: Commit deletion and purge operations**

```bash
git add \
  apps/gsmlg_gao_note/lib/gsmlg/gao_note/batch_actions.ex \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/batch_actions_test.exs
git commit -m "feat(gao-note): add atomic batch note deletion"
```

## Task 4: Add shared admin selection and checkbox primitives

**Files:**
- Create: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/batch_selection.ex`
- Create: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/batch_action_components.ex`
- Create: `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_batch_selection_test.exs`
- Create: `apps/gsmlg_admin_web/assets/js/hooks/indeterminate_checkbox.js`
- Create: `apps/gsmlg_admin_web/assets/js/hooks/indeterminate_checkbox.test.js`
- Modify: `apps/gsmlg_admin_web/assets/js/hooks.js:1-55`

- [ ] **Step 1: Write failing pure selection tests**

```elixir
defmodule GSMLG.AdminWeb.GaoNoteBatchSelectionTest do
  use ExUnit.Case, async: true
  alias GSMLG.AdminWeb.GaoNoteLive.BatchSelection

  test "toggles rows, all loaded rows, and tri-state status" do
    ids = ~w(a b c)
    selected = BatchSelection.toggle(MapSet.new(), "a")
    assert BatchSelection.state(selected, ids) == :mixed

    selected = BatchSelection.toggle_all(selected, ids)
    assert selected == MapSet.new(ids)
    assert BatchSelection.state(selected, ids) == :all
    assert BatchSelection.toggle_all(selected, ids) == MapSet.new()
  end

  test "reconcile removes IDs outside the loaded result" do
    assert BatchSelection.reconcile(MapSet.new(~w(a stale)), ~w(a b)) == MapSet.new(["a"])
  end
end
```

- [ ] **Step 2: Run and verify the missing-module failure**

```bash
unbuffer mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_batch_selection_test.exs
```

Expected: FAIL because `BatchSelection` is undefined.

- [ ] **Step 3: Implement the pure selection module**

```elixir
defmodule GSMLG.AdminWeb.GaoNoteLive.BatchSelection do
  @moduledoc false

  def toggle(selected, id) do
    if MapSet.member?(selected, id), do: MapSet.delete(selected, id), else: MapSet.put(selected, id)
  end

  def toggle_all(selected, loaded_ids) do
    loaded = MapSet.new(loaded_ids)
    if state(selected, loaded_ids) == :all,
      do: MapSet.difference(selected, loaded),
      else: MapSet.union(selected, loaded)
  end

  def reconcile(selected, loaded_ids),
    do: MapSet.intersection(selected, MapSet.new(loaded_ids))

  def state(_selected, []), do: :none
  def state(selected, loaded_ids) do
    loaded = MapSet.new(loaded_ids)
    count = loaded |> MapSet.intersection(selected) |> MapSet.size()
    cond do
      count == 0 -> :none
      count == MapSet.size(loaded) -> :all
      true -> :mixed
    end
  end
end
```

- [ ] **Step 4: Test and implement the indeterminate-checkbox hook**

```javascript
import { describe, expect, test } from "bun:test";
import IndeterminateCheckbox from "./indeterminate_checkbox.js";

describe("IndeterminateCheckbox", () => {
  test("synchronizes mounted and updated state", () => {
    const el = { dataset: { state: "mixed" }, indeterminate: false };
    const hook = { ...IndeterminateCheckbox, el };
    hook.mounted();
    expect(el.indeterminate).toBe(true);
    el.dataset.state = "all";
    hook.updated();
    expect(el.indeterminate).toBe(false);
  });
});
```

```javascript
const IndeterminateCheckbox = {
  mounted() { this.syncIndeterminate(); },
  updated() { this.syncIndeterminate(); },
  syncIndeterminate() {
    this.el.indeterminate = this.el.dataset.state === "mixed";
  },
};

export default IndeterminateCheckbox;
```

Import and register it as `IndeterminateCheckbox` in `hooks.js`.

- [ ] **Step 5: Run pure selection and hook tests**

```bash
unbuffer mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_batch_selection_test.exs
bun test apps/gsmlg_admin_web/assets/js/hooks/indeterminate_checkbox.test.js
```

Expected: both pass with zero failures.

- [ ] **Step 6: Add stateless functional UI components**

The shared checkbox renders native semantics and the hook:

```elixir
attr :id, :string, required: true
attr :checked, :boolean, default: false
attr :state, :atom, default: :none
attr :event, :string, required: true
attr :value_id, :string, default: nil
attr :label, :string, required: true

def selection_checkbox(assigns) do
  ~H"""
  <input
    id={@id}
    type="checkbox"
    class="checkbox checkbox-primary checkbox-sm"
    checked={@checked}
    aria-label={@label}
    aria-checked={if @state == :mixed, do: "mixed", else: to_string(@checked)}
    data-state={@state}
    phx-hook="IndeterminateCheckbox"
    phx-click={@event}
    phx-value-id={@value_id}
  />
  """
end
```

Also add stateless Notes/Recycle toolbars, the label-action modal, soft-delete modal, and permanent-purge modal. Use only DuskMoon surface/text tokens and semantic error variants. Components receive forms, options, counts, previews, and event names; they never query the Repo or own state.

Use these stable component IDs and contracts so the LiveView tests do not depend on presentation classes:

```elixir
def notes_toolbar(assigns)       # id="gao-note-batch-toolbar"
def label_modal(assigns)         # id="gao-note-batch-label-modal", submit="submit_batch_label"
def soft_delete_modal(assigns)   # id="gao-note-batch-delete-modal", confirm="batch_delete_notes"
def recycle_toolbar(assigns)     # id="gao-note-recycle-batch-toolbar"
def purge_modal(assigns)         # id="gao-note-recycle-purge-modal", submit="batch_purge_notes"
```

`label_modal/1` receives `form`, `action`, `label_options`, `selected_count`, `preview`, and `error`. `soft_delete_modal/1` receives `selected_count` and `error`. `purge_modal/1` receives `form`, `selected_count`, and `error`; its submit button has ID `gao-note-recycle-purge-confirm`.

- [ ] **Step 7: Commit shared primitives**

```bash
git add \
  apps/gsmlg_admin_web/assets/js/hooks.js \
  apps/gsmlg_admin_web/assets/js/hooks/indeterminate_checkbox.js \
  apps/gsmlg_admin_web/assets/js/hooks/indeterminate_checkbox.test.js \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/batch_action_components.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/batch_selection.ex \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_batch_selection_test.exs
git commit -m "feat(admin): add GaoNote batch selection primitives"
```

## Task 5: Integrate Notes selection and label actions

**Files:**
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/index.ex:4-9,17-30,41-54,91-158,380-422,1526-1605,1694-1921`
- Modify: `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs:1-510`

- [ ] **Step 1: Write failing row/header selection tests**

Create two notes, render `/gao_notes/notes`, call `render_async/1`, and assert:

```elixir
assert has_element?(view, "#gao-note-select-all[aria-label='Select all loaded notes']")
assert has_element?(view, "#gao-note-select-#{first.id}[aria-label='Select #{first.title}']")
refute has_element?(view, "#gao-note-batch-toolbar")

view |> element("#gao-note-select-#{first.id}") |> render_click()
assert has_element?(view, "#gao-note-batch-toolbar", "1 selected")
assert has_element?(view, "#gao-note-select-all[aria-checked='mixed']")

view |> element("#gao-note-select-all") |> render_click()
assert has_element?(view, "#gao-note-batch-toolbar", "2 selected")
assert has_element?(view, "#gao-note-select-all[aria-checked='true']")
```

Add one test proving a filter `push_patch` clears selection and one proving a refreshed loaded result reconciles missing IDs.

- [ ] **Step 2: Run and verify the missing UI failure**

```bash
unbuffer mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs
```

Expected: the new checkbox and toolbar selectors fail.

- [ ] **Step 3: Add Notes selection state and handlers**

Initialize:

```elixir
batch_selected: MapSet.new(),
batch_label_action: "add",
batch_label_form: to_form(%{
  "action" => "add",
  "match_label_setting_id" => "",
  "match_value" => "",
  "target_label_setting_id" => "",
  "target_value" => ""
}, as: :batch_label),
batch_label_settings: AsyncResult.loading(),
batch_label_preview: nil,
batch_label_error: nil
```

When applying `:index`, asynchronously load `GaoNote.list_label_settings(limit: 200)` into `:batch_label_settings`. Do not expose the note editor's free-text label-key input in this modal.

Implement events `toggle_batch_note`, `toggle_all_batch_notes`, and `clear_batch_selection` through `BatchSelection`. Clear selection when normalized filters change. Reconcile against loaded IDs after every async list result before enabling actions.

Replace `assign_async/4` for the Notes list with `start_async/3` so completion can reconcile selection explicitly:

```elixir
defp assign_notes_async(socket, opts) do
  socket
  |> assign(:notes, AsyncResult.loading(socket.assigns.notes))
  |> start_async(:load_gao_notes, fn -> GaoNote.list_notes(opts) end)
end

def handle_async(:load_gao_notes, {:ok, notes}, socket) do
  selected = BatchSelection.reconcile(socket.assigns.batch_selected, Enum.map(notes, & &1.id))
  {:noreply, assign(socket, notes: AsyncResult.ok(socket.assigns.notes, notes), batch_selected: selected)}
end

def handle_async(:load_gao_notes, {:exit, reason}, socket) do
  {:noreply, assign(socket, :notes, AsyncResult.failed(socket.assigns.notes, reason))}
end
```

Add exact helper definitions used by the template:

```elixir
defp loaded_note_ids(notes), do: notes |> async_value([]) |> Enum.map(& &1.id)

defp batch_selection_state(notes, selected),
  do: BatchSelection.state(selected, loaded_note_ids(notes))
```

- [ ] **Step 4: Replace `dm_table` with the scoped semantic table workaround**

Place the required upstream marker above a native table. Preserve the current Title link, label badges, timestamps, and per-row action modal verbatim from `index.ex:1837-1918`; only wrap them in explicit `<td>` cells and add row IDs.

Use this exact header structure:

```heex
<%# WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#145 %>
<div :if={!async_loading?(@notes)} class="overflow-x-auto rounded-2xl border border-outline-variant">
  <table id="gao-note-table" class="table table-bordered table-hover w-full">
    <thead>
      <tr>
        <th class="w-12">
          <BatchActionComponents.selection_checkbox
            id="gao-note-select-all"
            checked={batch_selection_state(@notes, @batch_selected) == :all}
            state={batch_selection_state(@notes, @batch_selected)}
            event="toggle_all_batch_notes"
            label="Select all loaded notes"
          />
        </th>
        <th>Title</th>
        <th>Labels</th>
        <th>Created</th>
        <th>Updated</th>
        <th><span class="sr-only">Actions</span></th>
      </tr>
    </thead>
```

Open `<tbody>`, iterate the same `async_value(@notes, [])`, and add this cell before the five existing column bodies moved verbatim from `index.ex:1837-1918`:

```heex
<td class="align-top">
  <BatchActionComponents.selection_checkbox
    id={"gao-note-select-#{note.id}"}
    checked={MapSet.member?(@batch_selected, note.id)}
    event="toggle_batch_note"
    value_id={note.id}
    label={"Select #{note.title}"}
  />
</td>
```

Close each row, `<tbody>`, table, and overflow wrapper. Preserve the existing interactive Title, Labels, and Actions markup exactly so single-note behavior and badge styling do not regress.

- [ ] **Step 5: Write failing modal-shape and preview tests**

Select notes, open the label modal, and exercise `change_batch_label_action` with Add, Edit, and Delete. Assert each action renders only its approved fields and every setting option comes from existing Label Settings.

Submit Add against one missing and one exact note and assert the success flash includes `1 changed, 1 unchanged`. Add focused tests for Add conflict preview/error retention, exact Edit matching, name-changing Edit, Delete by name, Delete by exact value, zero-match information, and invalid typed value retention.

- [ ] **Step 6: Parse modal forms into tagged operations without dynamic atoms**

```elixir
defp batch_label_operation(%{"action" => "add"} = params) do
  {:ok, {:add, %{label_setting_id: params["target_label_setting_id"], value: params["target_value"] || ""}}}
end

defp batch_label_operation(%{"action" => "edit"} = params) do
  {:ok,
   {:edit,
    %{
      match: %{
        label_setting_id: params["match_label_setting_id"],
        value: optional_match(params["match_value"])
      },
      replacement: %{
        label_setting_id: params["target_label_setting_id"],
        value: params["target_value"] || ""
      }
    }}}
end

defp batch_label_operation(%{"action" => "delete"} = params) do
  {:ok,
   {:delete,
    %{match: %{label_setting_id: params["match_label_setting_id"], value: optional_match(params["match_value"])}}}}
end

defp batch_label_operation(_params), do: {:error, "Select a label action."}

defp optional_match(value) when value in [nil, ""], do: :any
defp optional_match(value), do: {:exact, String.trim(value)}
```

- [ ] **Step 7: Implement preview and submission behavior**

Build preview counts only from selected structs in the loaded `@notes` result and the loaded Label Setting catalog. Do not query a broader filtered set. On submit call `GaoNote.batch_mutate_note_labels/3` with sorted selected IDs.

On every `change_batch_label_action` event, resolve the selected setting structs from the already loaded catalog and call `LabelValue.validate/2` for Add/replacement values and supplied exact match values. Assign field-level errors and disable submission when validation fails. The domain repeats the same validation under lock.

Translate structured domain errors into actionable copy. Retain modal and selection on error. On success, close through:

```elixir
push_event(socket, "close-dialog", %{id: "gao-note-batch-label-modal"})
```

Then clear selection, reload the current filter options, and flash the authoritative `matched`, `changed`, and `unchanged` counts.

Map errors explicitly:

```elixir
defp batch_error_text({:label_conflict, %{operation: :add, note_ids: ids}}),
  do: "#{length(ids)} selected notes already use that label name with another value. Nothing changed."

defp batch_error_text({:label_conflict, %{operation: :edit, note_ids: ids}}),
  do: "#{length(ids)} matching notes already contain the replacement label name. Nothing changed."

defp batch_error_text({:notes_unavailable, %{ids: ids}}),
  do: "#{length(ids)} selected notes changed or disappeared. Reload the list and try again."

defp batch_error_text({:invalid_label_value, %{errors: errors}}), do: Enum.join(errors, ", ")
defp batch_error_text(reason), do: "Batch action failed: #{inspect(reason)}"
```

- [ ] **Step 8: Run focused Notes and domain tests**

```bash
unbuffer mix test \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/batch_actions_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs
```

Expected: PASS with zero failures.

- [ ] **Step 9: Commit Notes label actions**

```bash
git add \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/index.ex \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs
git commit -m "feat(gao-note): add batch label actions to notes"
```

## Task 6: Integrate Notes atomic soft deletion

**Files:**
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/index.ex`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/batch_action_components.ex`
- Modify: `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs`

- [ ] **Step 1: Write failing soft-delete modal tests**

Select two notes and assert:

```elixir
assert has_element?(view, "#gao-note-batch-delete-modal")
assert has_element?(view, "#gao-note-batch-delete-confirm", "Move 2 selected notes")
```

Confirm and assert both notes leave the active query, enter `list_deleted_notes/1`, selection clears, the modal closes, and the flash reports `2 notes moved to the Recycle Bin`.

Add a stale-selection test: delete one selected note through the context before confirming, then assert the other note remains active and the modal/selection remain open.

- [ ] **Step 2: Run and verify the missing modal failure**

```bash
unbuffer mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs
```

Expected: the new batch-delete modal assertions fail.

- [ ] **Step 3: Implement modal and event behavior**

```heex
<p>Move {@selected_count} selected notes to the Recycle Bin?</p>
<p class="text-sm text-on-surface-variant">They can be restored later.</p>
```

The `batch_delete_notes` event calls:

```elixir
GaoNote.batch_delete_notes(
  socket.assigns.batch_selected |> MapSet.to_list() |> Enum.sort(),
  current_actor(socket)
)
```

Use the label modal's success/error close and retain rules. Do not schedule attachment purges and do not change the existing single-note `delete` event.

- [ ] **Step 4: Run focused tests**

```bash
unbuffer mix test \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/batch_actions_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs
```

Expected: PASS with zero failures.

- [ ] **Step 5: Commit soft deletion UI**

```bash
git add \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/batch_action_components.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/index.ex \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs
git commit -m "feat(gao-note): add batch soft deletion"
```

## Task 7: Integrate Recycle Bin atomic permanent deletion

**Files:**
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/recycle_bin_live/index.ex:4-26,46-62,64-167`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/batch_action_components.ex`
- Modify: `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs:450-520`

- [ ] **Step 1: Write failing selection and confirmation tests**

Create and soft-delete two notes, render the Recycle Bin, and assert:

```elixir
assert has_element?(view, "#gao-note-recycle-select-all")
refute has_element?(view, "#gao-note-recycle-batch-toolbar")

view |> element("#gao-note-recycle-select-all") |> render_click()
assert has_element?(view, "#gao-note-recycle-batch-toolbar", "2 selected")
assert has_element?(view, "#gao-note-recycle-batch-purge")
assert has_element?(view, "#gao-note-recycle-purge-confirm[disabled]")
```

Change confirmation to `DELETE`, assert the button enables, submit, and verify both notes are permanently absent with per-note purge logs. Add stale-selection retention and existing per-row Restore assertions.

- [ ] **Step 2: Run and verify the missing UI failure**

```bash
unbuffer mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs
```

Expected: Recycle Bin selection selectors fail.

- [ ] **Step 3: Add selection and refresh behavior**

Initialize:

```elixir
batch_selected: MapSet.new(),
purge_confirmation: "",
purge_error: nil
```

Reuse `BatchSelection` for row/header/clear events. Add a checkbox header and row cells to the existing native table and change the empty-state `colspan` from 4 to 5. Explicit Refresh clears selection and confirmation. Failed purge retains selection; successful purge clears it.

- [ ] **Step 4: Implement exact DELETE confirmation and submission**

The modal states that notes and attachments cannot be restored and storage deletion is asynchronous. Enable submission only when:

```elixir
socket.assigns.purge_confirmation == "DELETE"
```

Reject other values without calling the context. Exact confirmation calls:

```elixir
GaoNote.batch_permanently_delete_notes(
  socket.assigns.batch_selected |> MapSet.to_list() |> Enum.sort(),
  current_actor(socket)
)
```

On success close, clear, refresh, and flash the purged count. On structured stale/job/database errors, keep modal and selection.

- [ ] **Step 5: Run focused Recycle Bin and domain tests**

```bash
unbuffer mix test \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/batch_actions_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs
```

Expected: PASS with zero failures.

- [ ] **Step 6: Commit Recycle Bin purge UI**

```bash
git add \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/batch_action_components.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/recycle_bin_live/index.ex \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs
git commit -m "feat(gao-note): add recycle bin batch purge"
```

## Task 8: Focused verification and scope audit

**Files:** Verify only files listed in Tasks 1-7.

- [ ] **Step 1: Format only scoped Elixir files**

```bash
mix format \
  apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex \
  apps/gsmlg_gao_note/lib/gsmlg/gao_note/audit.ex \
  apps/gsmlg_gao_note/lib/gsmlg/gao_note/batch_actions.ex \
  apps/gsmlg_gao_note/lib/gsmlg/gao_note/label_value.ex \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/batch_actions_test.exs \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/label_value_test.exs \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/batch_action_components.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/batch_selection.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/index.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/recycle_bin_live/index.ex \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_batch_selection_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs
```

Expected: exit 0 and only scoped formatting changes.

- [ ] **Step 2: Run all focused automated checks**

```bash
unbuffer mix test \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/label_value_test.exs \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/batch_actions_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_batch_selection_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs

bun test apps/gsmlg_admin_web/assets/js/hooks/indeterminate_checkbox.test.js
```

Expected: all focused ExUnit and Bun tests pass with zero failures.

- [ ] **Step 3: Verify formatting and diff hygiene**

```bash
mix format --check-formatted \
  apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex \
  apps/gsmlg_gao_note/lib/gsmlg/gao_note/audit.ex \
  apps/gsmlg_gao_note/lib/gsmlg/gao_note/batch_actions.ex \
  apps/gsmlg_gao_note/lib/gsmlg/gao_note/label_value.ex \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/batch_actions_test.exs \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/label_value_test.exs \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/batch_action_components.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/batch_selection.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/index.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/recycle_bin_live/index.ex \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_batch_selection_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs

git diff --check
```

Then inspect:

```bash
git status --short
git diff --stat
git diff --name-only
```

Expected: formatting and diff checks exit 0.

- [ ] **Step 4: Audit scope and requirements**

Confirm all of these directly from the diff:

- Only scoped GaoNote domain, admin LiveView, test, and hook files changed.
- Existing untracked API-discovery documents remain untouched.
- No migration, route, REST, OpenAPI, MCP, pagination, batch restore, or filter-wide-selection change exists.
- `WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#145` appears immediately above the native Notes table.
- Single-note create/edit/delete/restore/purge controls and contracts remain intact.

- [ ] **Step 5: Commit only verification formatting if needed**

Inspect `git status --short`, stage only exact scoped files changed by formatting, and commit:

```bash
git add -- \
  apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex \
  apps/gsmlg_gao_note/lib/gsmlg/gao_note/audit.ex \
  apps/gsmlg_gao_note/lib/gsmlg/gao_note/batch_actions.ex \
  apps/gsmlg_gao_note/lib/gsmlg/gao_note/label_value.ex \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/batch_actions_test.exs \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/label_value_test.exs \
  apps/gsmlg_admin_web/assets/js/hooks.js \
  apps/gsmlg_admin_web/assets/js/hooks/indeterminate_checkbox.js \
  apps/gsmlg_admin_web/assets/js/hooks/indeterminate_checkbox.test.js \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/batch_action_components.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/batch_selection.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/index.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/recycle_bin_live/index.ex \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_batch_selection_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs
git commit -m "style(gao-note): format batch action changes"
```

Do not create this commit when formatting produced no changes.
