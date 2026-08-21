# GaoNote Batch Actions Design

## Goal

Add explicit, atomic batch actions to the GaoNote Notes and Recycle Bin admin
LiveViews.

On `/gao_notes/notes`, administrators can select loaded notes and perform one of
these actions:

- Add one label to every selected note.
- Edit labels matching a name or exact `name=value` selector.
- Delete labels matching a name or exact `name=value` selector.
- Soft-delete every selected note into the Recycle Bin.

On `/gao_notes/recycle_bin`, administrators can select loaded deleted notes and
permanently delete them as one atomic database operation.

This design uses the existing Phoenix LiveView, Ecto, GaoNote audit-log, and
attachment-purge boundaries. It does not add REST or MCP operations.

## Existing Constraints

The current Notes LiveView loads at most 100 filtered active notes. The current
Recycle Bin LiveView loads at most 200 deleted notes. Neither view has
pagination.

GaoNote stores at most one label for each label setting on a note. Label
settings govern the label name and value type. Note deletion is soft deletion;
only a Recycle Bin purge permanently deletes the database record and schedules
attachment-file cleanup.

The existing single-note context functions do not form one transaction across
multiple notes. Batch behavior therefore belongs in dedicated GaoNote context
operations rather than a LiveView loop over the single-note APIs.

## Notes Selection and Batch Toolbar

Add a leading checkbox column to the existing `/gao_notes/notes` table.

- A row checkbox selects or clears that note.
- The header checkbox selects or clears every currently loaded row.
- The header checkbox exposes none, all, and mixed states accessibly.
- Selection contains only explicit loaded note IDs. It never expands to hidden
  notes that happen to match the current filters.
- Changing search or label filters clears selection.
- A failed modal validation or domain operation retains selection.
- A successful batch operation clears selection and reloads the current
  filtered list.

Selection state is a `MapSet` owned by the Notes LiveView. The LiveView
reconciles it against the IDs returned by every asynchronous list load so stale
or no-longer-loaded rows cannot remain selected.

When at least one note is selected, render a batch toolbar between the filters
and table. It contains:

- The selected-note count.
- A ghost `Clear` action.
- A secondary `Edit labels` action.
- An error-colored `Delete selected` action.

The existing `New` button remains the page's primary action. The toolbar wraps
on narrow viewports and remains in normal document flow rather than floating
over table content.

## Batch Label Modal

`Edit labels` opens one modal. Each submission performs exactly one operation.
An action selector switches among Add, Edit, and Delete and renders only the
fields needed by that action.

All label-name controls select existing GaoNote Label Settings by ID. Batch
actions cannot auto-create label settings. An administrator creates a new
setting deliberately on `/gao_notes/label_settings` before using it in a batch.

Values are normalized and validated against the selected label setting's value
type before submission and again in the authoritative domain operation.

### Add

The Add form contains:

- Label setting.
- Label value.

For every selected note:

- If the label name is absent, insert `name=value`.
- If the exact normalized `name=value` already exists, leave the note
  unchanged.
- If the name exists with another value, reject the complete batch.

Add never silently changes an existing value.

### Edit

The Edit form contains:

- Match label setting.
- Optional exact match value.
- Replacement label setting.
- Replacement value.

A blank match value means match the label name regardless of its current value.
A supplied value means exact stored-value equality. Only matching labels on the
selected notes are changed.

The replacement may change the value, label name, or both. If the replacement
uses a different name and a matched note already has that replacement name as a
separate label, reject the complete batch rather than overwriting or merging
the existing label.

An Edit with no matching selected notes is a successful no-op. It creates no
audit logs.

### Delete

The Delete form contains:

- Match label setting.
- Optional exact match value.

A blank value deletes that label name from every selected note where it occurs.
A supplied value deletes only exact `name=value` matches. Other labels remain
unchanged.

A Delete with no matching selected notes is a successful no-op. It creates no
audit logs.

### Preview and Submission Feedback

Because selection is limited to loaded notes and their labels are already
preloaded, the LiveView derives a non-authoritative preview without another
database query.

- Add shows notes that would change, notes already holding the exact label, and
  notes with conflicting values.
- Edit shows matching notes and visible replacement-name conflicts.
- Delete shows matching notes.

The modal states the selected-note count and the currently matching count before
submission. Concurrent changes may make the preview stale, so the transaction
always repeats every check.

Validation and transaction errors keep the modal open. Successful submissions
close it, clear selection, reload the list, and display the authoritative result
summary.

## Label Mutation Domain Contract

Add a dedicated context operation:

```elixir
batch_mutate_note_labels(note_ids, operation, actor)
```

The LiveView converts form parameters to one of these tagged operations:

```elixir
{:add, %{label_setting_id: id, value: value}}

{:edit,
 %{
   match: %{label_setting_id: id, value: :any | {:exact, value}},
   replacement: %{label_setting_id: id, value: value}
 }}

{:delete,
 %{match: %{label_setting_id: id, value: :any | {:exact, value}}}}
```

The tagged selector distinguishes matching any value from matching an exact
stored value. Context input uses stable Label Setting IDs so a concurrent rename
does not change which setting the administrator selected.

The operation accepts between 1 and 100 unique, valid note IDs. It returns a
summary shaped as:

```elixir
%{
  selected: selected_count,
  matched: matched_count,
  changed: changed_count,
  unchanged: unchanged_count
}
```

`matched` is the selected count for Add. For Edit and Delete it is the number of
selected notes containing a label matching the source selector. `changed` counts
notes whose persisted labels changed. `unchanged` is `selected - changed`.

### Atomic Execution

The context performs the following work in one repository transaction:

1. Normalize the operation and reject malformed or duplicate note IDs.
2. Load and lock referenced Label Settings.
3. Load and lock all selected active notes in deterministic ID order.
4. Verify that the number of locked notes exactly equals the requested unique
   ID count.
5. Load the selected notes' labels and repeat value, match, and conflict
   validation against the locked state.
6. Apply all label inserts, updates, or deletes.
7. Insert one audit log for every note whose labels changed.
8. Return the result summary and commit.

If a selected note is deleted concurrently, a label setting disappears, a
typed value is invalid, a target-name collision occurs, or any database or log
insert fails, the transaction rolls back every mutation.

Locks are acquired in deterministic note-ID order to avoid deadlocks between
overlapping batch actions. The context remains authoritative even when the
LiveView preview found no conflict.

The operation changes only matching label rows. It does not replace a note's
complete label vector and does not touch its title, content, attachments, or
unmentioned labels.

## Notes Batch Soft Deletion

`Delete selected` opens a separate error-styled confirmation modal. It states:

> Move N selected notes to the Recycle Bin? They can be restored later.

Add this context operation:

```elixir
batch_delete_notes(note_ids, actor)
```

It accepts between 1 and 100 unique, valid IDs. In one transaction it locks all
selected active notes in deterministic order, verifies that none became missing
or deleted, sets `deleted_at` on every note, and inserts the normal per-note
`delete` audit logs.

Any stale note, update failure, or audit failure rolls back every deletion. The
operation does not schedule attachment purges. Attachment files remain available
for note restoration until a later permanent purge.

On success the LiveView clears selection, reloads the current filtered active
list, and reports the deleted count.

## Audit Logging

Batch operations preserve the existing action vocabulary:

- Label changes use `update`.
- Soft deletion uses `delete`.
- Permanent deletion uses `purge`.

Each changed note gets its own audit entry with the current actor. Details include
the normal note title and fields plus batch metadata identifying the operation
kind. Audit insertion participates in the same transaction as its mutation.

No audit entry is inserted for an unchanged note or a zero-match operation.

## Recycle Bin Selection

Add a leading checkbox column to `/gao_notes/recycle_bin` with the same row,
header, mixed-state, and accessibility behavior as the Notes table.

The selection applies only to currently loaded deleted notes. The Recycle Bin
currently loads at most 200 rows, so all 200 may be selected. An explicit refresh
clears selection. A failed purge retains selection; a successful purge clears it
and reloads the list.

When selection is non-empty, render a toolbar containing:

- The selected-note count.
- A ghost `Clear` action.
- An error-colored `Delete selected permanently` action.

Restore remains a per-row action. Batch restore is out of scope.

## Recycle Bin Permanent Deletion

`Delete selected permanently` opens a dedicated error-styled modal. It states
the exact selected-note count, explains that notes and attachments cannot be
restored, and explains that attachment objects will be scheduled for permanent
storage deletion.

The confirmation button remains disabled until the administrator enters
`DELETE` exactly.

Add this context operation:

```elixir
batch_permanently_delete_notes(note_ids, actor)
```

It accepts between 1 and 200 unique, valid IDs. In one transaction it:

1. Loads and locks every selected deleted note in deterministic order.
2. Verifies that every requested note is still in the Recycle Bin.
3. Collects all associated attachment storage-file IDs.
4. Schedules the existing attachment purge jobs.
5. Permanently deletes every selected note.
6. Inserts one normal `purge` audit entry per deleted note with batch metadata.
7. Returns the selected and purged counts and commits.

If validation, purge-job insertion, deletion, or logging fails, no note is
permanently deleted and no newly scheduled purge job survives the rollback.
Actual object-storage deletion remains asynchronous through the existing purge
worker after the transaction commits.

## Error Handling

Return structured domain errors that the LiveViews translate into actionable
modal messages. Required error categories include:

- Invalid, duplicate, empty, or over-limit note selections.
- Selected active notes that became unavailable before a label or soft-delete
  action.
- Selected deleted notes that left the Recycle Bin before a purge.
- Missing referenced Label Settings.
- Invalid typed label values.
- Add conflicts where a selected note already holds another value for the name.
- Edit conflicts where a matched note already holds the replacement name.
- Database, audit-log, and purge-job failures.

Conflict errors include affected note IDs and a safe human-readable explanation.
The UI may resolve visible IDs to titles, but the domain error does not depend on
titles remaining unchanged.

Zero-match Edit and Delete results are successful informational no-ops rather
than errors.

## Testing

### GaoNote Context Tests

Focused domain tests cover:

- Add to missing labels.
- Identical Add no-ops.
- Add value conflicts and complete rollback.
- Edit matching by name and exact `name=value`.
- Edit value changes, name changes, and combined changes.
- Edit replacement-name conflicts and complete rollback.
- Delete matching by name and exact value.
- Zero-match Edit and Delete behavior.
- Preservation of unmentioned labels, title, content, and attachments.
- Missing settings and invalid typed values.
- Empty, duplicate, invalid, stale, and over-limit note IDs.
- Deterministic locking for overlapping concurrent operations.
- Atomic batch soft deletion.
- Per-note actor audit entries with batch metadata.
- No audit entries for unchanged notes.
- Atomic permanent deletion of deleted notes.
- Attachment purge-job insertion on permanent deletion.
- Rollback of notes, logs, and purge jobs when any purge step fails.

### Admin LiveView Tests

Focused Notes LiveView tests cover:

- Individual, header, and mixed checkbox states.
- Selection reconciliation and clearing when filters change.
- Batch toolbar visibility, responsive structure, and selected count.
- Conditional Add, Edit, and Delete fields.
- Selection of only existing Label Settings.
- Match and conflict previews from loaded notes.
- Successful result summaries.
- Modal and selection retention on error.
- Selection clearing and list refresh on success.
- Atomic soft-delete confirmation and Recycle Bin results.
- Accessible checkbox names, modal labels, focus behavior, and keyboard actions.

Focused Recycle Bin LiveView tests cover:

- Explicit row and header selection.
- Permanent-delete toolbar visibility and count.
- Exact `DELETE` confirmation requirement.
- Successful permanent deletion and attachment purge scheduling.
- Selection retention and unchanged notes after an error.
- Existing per-row Restore behavior remaining available.

Verification runs only the GaoNote domain and GaoNote Admin LiveView test files
affected by this feature, formatting checks for modified files, and
`git diff --check`. Unrelated test failures do not expand this feature's scope.

## Scope Boundaries

In scope:

- Dedicated atomic batch operations in `GSMLG.GaoNote`.
- Notes-table selection, label-action modal, and soft-delete confirmation.
- Recycle Bin selection and permanent-delete confirmation.
- Existing audit-log and attachment-purge infrastructure.
- Focused context and LiveView tests.

Out of scope:

- Database migrations.
- REST, OpenAPI, or MCP batch operations.
- New background processes or PubSub topics.
- Batch restore.
- Filter-wide selection of unloaded notes.
- Pagination or changes to the existing list limits.
- Multiple label operations in one submission.
- Auto-creation of Label Settings from batch actions.
- Changes to single-note create, edit, delete, restore, or purge behavior.
