# GaoNote Note-Owned Attachments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace independent GaoNote attachment CRUD with globally identified, storage-backed attachments reconciled as part of note create and update.

**Architecture:** `GSMLG.GaoNote.AttachmentInput.cast/1` validates one input.
`GSMLG.GaoNote.Attachments.prepare/3` validates the complete list and stages
new objects, `transact/2` wraps the note transaction with staged-object
compensation, and `reconcile/2` locks and persists the final list while
scheduling cleanup. `GSMLG.GaoNote` owns aggregate create/update/delete.
Public, MCP, and admin surfaces use the same metadata-only presenter shape and
the public/admin `GaoNoteAttachmentContentController` modules serve raw bytes.

**Tech Stack:** Elixir 1.18, Ecto/PostgreSQL, Phoenix LiveView, Oban, `GSMLG.Storage`, AWS S3 client, Backplane MCP Protocol, Phoenix DuskMoon.

**Verification policy:** The implementation includes scoped tests, but commands are not run until the user explicitly authorizes validation.

**Git policy:** Do not stage, commit, or push unless the user explicitly requests it.

**Implementation status:** Tasks 1-7 are implemented. Scoped tests, formatting,
compilation, assets, and server/browser validation have not been run for this
cleanup.

---

### Task 1: Replace the attachment schema and define the input contract

**Files:**
- Create: `apps/gsmlg/priv/repo/migrations/20260718000000_redesign_gao_note_attachments.exs`
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/attachment.ex`
- Create: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/attachment_input.ex`
- Replace: `apps/gsmlg_gao_note/test/gsmlg/gao_note_attachment_migration_test.exs`
- Create: `apps/gsmlg_gao_note/test/gsmlg/gao_note/attachment_input_test.exs`

- [x] **Step 1: Write the destructive schema migration**

```elixir
defmodule GSMLG.Repo.Migrations.RedesignGaoNoteAttachments do
  use Ecto.Migration

  def up do
    drop table(:gao_note_attachments)

    create table(:gao_note_attachments, primary_key: false) do
      add :id, :text, primary_key: true
      add :note_id, references(:gao_notes, type: :binary_id, on_delete: :delete_all),
        null: false

      add :storage_file_id,
          references(:storage_files, type: :binary_id, on_delete: :restrict),
          null: false

      add :path, :text, null: false
      add :mime, :text, null: false
      add :description, :text, null: false, default: ""
      timestamps(type: :utc_datetime_usec)
    end

    create index(:gao_note_attachments, [:note_id])
    create unique_index(:gao_note_attachments, [:storage_file_id])
    create unique_index(:gao_note_attachments, [:note_id, :path])
  end

  def down do
    raise "the GaoNote attachment hard break is intentionally irreversible"
  end
end
```

- [x] **Step 2: Rewrite the persisted attachment schema**

```elixir
@primary_key {:id, :string, autogenerate: false}
@foreign_key_type :binary_id

schema "gao_note_attachments" do
  belongs_to :note, Note
  belongs_to :storage_file, StorageFile
  field :path, :string
  field :mime, :string
  field :description, :string, default: ""
  timestamps()
end
```

Expose `normalize_path/1` as a pure function. It must trim, convert `\` to `/`,
drop empty and `.` segments, reject schemes, roots, drive prefixes, and `..`,
then return `{:ok, "./" <> normalized}`.

- [x] **Step 3: Add strict persisted-row changesets**

`Attachment.changeset/2` casts the persisted fields, applies the empty
description default, validates UTF-8/NUL safety and required text, canonicalizes
the path, and names the note/storage foreign-key and identity/path uniqueness
constraints.

- [x] **Step 4: Add the boundary input module**

`AttachmentInput.cast/1` accepts only `id`, `path`, `mime`, `description`,
`content`, `content_base64`, and internal `upload`. It normalizes known
string/atom keys without creating atoms, decodes standard padded Base64,
requires equal bytes when both content forms reach the aggregate or public
HTTP boundary, and leaves bytes absent for a retained attachment. The strict
MCP schema permits at most one content form. `GSMLG.GaoNote.Attachments`
accepts a content-free `%Plug.Upload{}` only from the trusted admin flow;
trusted uploads are mutually exclusive with both public content forms, and
tuple uploads are rejected by the aggregate boundary.

- [x] **Step 5: Replace migration and input tests**

Cover text IDs, required fields, global storage-file uniqueness, per-note path
uniqueness, default description, canonical paths, traversal rejection, strict
Base64, equal dual inputs, and conflicting dual inputs.

- [ ] **Step 6: Prepare scoped verification**

```bash
unbuffer mix test \
  apps/gsmlg_gao_note/test/gsmlg/gao_note_attachment_migration_test.exs \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/attachment_input_test.exs
```

Expected result: both files pass after the migration is applied to the test DB.

### Task 2: Add confirmed storage deletion and bounded-memory reads

**Files:**
- Modify: `apps/gsmlg_storage/lib/gsmlg/storage.ex`
- Modify: `apps/gsmlg_storage/lib/gsmlg/storage/s3_client.ex`
- Modify: `apps/gsmlg_storage/lib/gsmlg/storage/storage_file.ex`
- Modify: `apps/gsmlg_gao_note/mix.exs`
- Create: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/workers/storage_file_purge_worker.ex`
- Modify: `config/config.exs`
- Modify: `apps/gsmlg_storage/test/gsmlg/storage_test.exs`
- Create: `apps/gsmlg_gao_note/test/gsmlg/gao_note/workers/storage_file_purge_worker_test.exs`

- [x] **Step 1: Make S3 deletion failure observable**

`Storage.purge/1` reloads the soft-deleted row, rejects non-deleted rows,
deletes every variant and then the original object, and deletes the database
row only after those operations succeed. Storage errors remain errors so Oban
can retry.

- [x] **Step 2: Permit empty attachment objects**

Storage upload validation permits zero-byte data. Empty attachment content is
valid and creates a zero-size storage row.

- [x] **Step 3: Add ranged S3 reads**

`GSMLG.Storage.read_range/3` validates an inclusive range and active storage
row, then delegates to `GSMLG.Storage.S3Client.get_object_range/4`.
`S3Client` supplies the generated AWS client arguments and the
`Range: bytes=FIRST-LAST` value. Raw controllers use this bounded API rather
than `Storage.stream/1`.

- [x] **Step 4: Add Oban as a direct GaoNote dependency**

```elixir
{:oban, "~> 2.18"}
```

The worker belongs in `gsmlg_gao_note`, which already depends on both `gsmlg`
and `gsmlg_storage`. Placing it in `gsmlg` would create an invalid dependency
cycle.

- [x] **Step 5: Add an idempotent purge worker**

`GSMLG.GaoNote.Workers.StorageFilePurgeWorker` validates its UUID, GaoNote
storage type, empty variant map, and supported status. Missing rows and already
purged rows succeed; invalid jobs are cancelled; active rows are soft-deleted
then purged; S3 failures return `{:error, reason}` for retry.

- [x] **Step 6: Enable the cleanup queue**

```elixir
config :gsmlg, Oban,
  repo: GSMLG.Repo,
  queues: [translations: 5, storage_cleanup: 2],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}
  ]
```

- [x] **Step 7: Add storage and worker regression tests**

Verify range reads, successful purge, preserved DB rows on S3 deletion error,
zero-byte storage records, active-to-deleted-to-purged worker behavior,
idempotent missing-row behavior, and retryable S3 failures.

- [ ] **Step 8: Prepare scoped verification**

```bash
unbuffer mix test \
  apps/gsmlg_storage/test/gsmlg/storage_test.exs \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/workers/storage_file_purge_worker_test.exs
```

Expected result: storage rows survive failed object deletion and ranged reads
return only the requested bytes.

### Task 3: Reconcile attachments inside note writes

**Files:**
- Create: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/attachments.ex`
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex`
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/note.ex`
- Modify: `apps/gsmlg_gao_note/test/gsmlg/gao_note_test.exs`

- [x] **Step 1: Define the reconciliation result**

`Attachments.prepare/3` accepts `note_id`, the complete raw attachment list,
and the uploader ID. It returns a private map containing `note_id`, prepared
entries, the current-row snapshot, and staged files. There is no public
prepared struct.

- [x] **Step 2: Validate aggregate-level identity and paths**

Reject:

- Duplicate payload IDs.
- Duplicate canonical paths.
- Empty content on new IDs.
- A global ID owned by another note.
- MIME changes without replacement bytes.

Cross-note ownership returns
`{:error, {:attachment, %{code: :owned_by_another_note, id: id, owner_note_id: owner_id}}}`.
Duplicate IDs and paths return `{:attachments, %{code: :duplicate_id, ...}}`
and `{:attachments, %{code: :duplicate_path, ...}}`; stale snapshots return
`{:attachments, %{code: :stale}}`.

- [x] **Step 3: Stage new and replacement files**

`Attachments` sends either `{Path.basename(path), bytes}` or a trusted
`%Plug.Upload{}` to
`Storage.upload(source, note_id, "gao_note_attachment", opts)`. Storage detects
the MIME; `Attachments` compares it with the submitted MIME and returns
`{:attachment, %{code: :mime_mismatch, ...}}` on mismatch.

Retained IDs reuse their current `storage_file_id`. Replacement IDs receive a
new storage object and mark the old object obsolete.

- [x] **Step 4: Add prepared rows to the note transaction**

For create, allocate the note UUID before staging:

```elixir
note = %Note{id: Ecto.UUID.generate()}
```

`GaoNote.create_note/2` and `update_note/3` call
`Attachments.transact(plan, operation)`. Inside that transaction they persist
the note and labels and call `Attachments.reconcile(note.id, plan)`.
`reconcile/2` advisory-locks requested IDs, locks current rows, rejects a stale
snapshot or cross-note owner, removes missing rows, temporarily moves retained
paths for atomic swaps, persists the final rows, and inserts purge jobs.
Transaction failure invokes `Attachments.cleanup/1` for staged files while
leaving existing rows and objects untouched.

- [x] **Step 5: Enforce full-list update semantics**

Add `attachments` to `@note_attr_keys`.

- Create defaults missing `attachments` to `[]`.
- Update returns a validation error when `attachments` is absent.
- `[]` removes all attachments.
- `set_labels/3` remains a label-only operation and does not call the
  full-aggregate update path.

- [x] **Step 6: Replace independent attachment APIs**

The context does not export global attachment list/get functions or independent
attachment mutations. It exposes the implemented note-scoped functions
`get_attachment_by_path/2`, `get_deleted_attachment_by_path/2`, and
`read_attachment_text/2`, delegating to `Attachments.get_by_path/2`,
`get_deleted_by_path/2`, and `read_text/2`. Active lookup excludes soft-deleted
notes; deleted lookup is used only by admin content serving; text reads reject
invalid UTF-8 and NUL bytes.

- [x] **Step 7: Extend permanent deletion**

Before deleting a soft-deleted note, collect attachment storage IDs and insert
one `GSMLG.GaoNote.Workers.StorageFilePurgeWorker` job per ID in the same
database transaction.
Soft-delete and restore behavior remains unchanged.

- [x] **Step 8: Replace context tests**

Cover aggregate create, retain, add, metadata edit, replacement, removal,
duplicate paths, global ID conflicts, MIME mismatch, failed transaction
compensation, soft-delete/restore retention, and purge jobs.

- [ ] **Step 9: Prepare scoped verification**

```bash
unbuffer mix test apps/gsmlg_gao_note/test/gsmlg/gao_note_test.exs
```

Expected result: no independent attachment operation remains and complete-list
note updates reconcile rows and storage lifecycle correctly.

### Task 4: Flatten note presentation and simplify MCP

**Files:**
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/presenter.ex`
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/tools.ex`
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/resources.ex`
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/admin_server.ex`
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/readonly_server.ex`
- Modify: `apps/gsmlg_gao_note/test/gsmlg/gao_note/presenter_test.exs`
- Modify: `apps/gsmlg_gao_note/test/gsmlg/gao_note/mcp_test.exs`

- [x] **Step 1: Replace attachment presentation**

```elixir
def attachment(%Attachment{} = attachment) do
  %{
    "id" => attachment.id,
    "path" => attachment.path,
    "mime" => attachment.mime,
    "description" => attachment.description || "",
    "content_url" =>
      "/api/gao_notes/#{attachment.note_id}/attachments/" <>
        URI.encode(String.trim_leading(attachment.path, "./"))
  }
end
```

Never return `storage_file_id`, nested storage metadata, visibility, storage
keys, `content`, or `content_base64`.

- [x] **Step 2: Remove independent MCP components**

Remove `gao_note.list_attachments` and all
`gao_note.attachments.*` tool names, schemas, dispatch clauses, descriptions,
annotations, and generated component modules.

Remove `Resources.NoteAttachments`, `Resources.Attachment`, their URI dispatch
clauses, and both server registrations.

- [x] **Step 3: Add aggregate attachment schemas**

Create uses an optional attachment list with default `[]`; update requires the
complete list. `GSMLG.GaoNote.MCP.Tools` uses a strict nested Peri validator and
an explicit JSON Schema object with `additionalProperties: false`. The nested
schema exposes only `id`, `path`, `mime`, `description`, `content`, and
`content_base64`, with exactly one public content form when content is sent.

Remove the 5 MB MCP-specific Base64 limit and its decoder. The domain boundary
owns strict decoding.

- [x] **Step 4: Preserve label-only mutation**

Change `gao_note.set_labels` to call `GaoNote.set_labels/3` directly so the new
required update attachment list cannot remove files.

- [x] **Step 5: Rewrite presenter and MCP tests**

Assert the flat attachment shape, absence of storage internals and bytes,
aggregate create/update schemas, reduced tool/resource lists, and removal of
independent attachment operations.

- [ ] **Step 6: Prepare scoped verification**

```bash
unbuffer mix test \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/presenter_test.exs \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/mcp_test.exs
```

Expected result: MCP exposes attachments only through note create, update, and
complete note reads.

### Task 5: Add note-relative HTTP writes and downloads

**Files:**
- Modify: `apps/gsmlg_web/lib/gsmlg/web/router.ex`
- Modify: `apps/gsmlg_web/lib/gsmlg/web/controllers/gao_note_controller.ex`
- Modify: `apps/gsmlg_web/lib/gsmlg/web/controllers/gao_note_json.ex`
- Create: `apps/gsmlg_web/lib/gsmlg/web/controllers/gao_note_attachment_content_controller.ex`
- Create: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/controllers/gao_note_attachment_content_controller.ex`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/router.ex`
- Modify: `apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_controller_test.exs`
- Create: `apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_attachment_content_controller_test.exs`
- Create: `apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/gao_note_attachment_content_controller_test.exs`
- Modify: `apps/gsmlg_web/test/gsmlg_web/controllers/api_error_controller_test.exs`

- [x] **Step 1: Remove stale public routes**

Delete `/gao_notes/:id/references`, `/gao_notes/:id/assets`, their controller
actions, JSON render functions, and obsolete test blocks.

- [x] **Step 2: Add authenticated note writes**

The authenticated public API scope exposes note create plus PUT/PATCH update.

Create and update pass the authenticated actor to `GSMLG.GaoNote`. Map malformed
content and unknown fields to `400`, semantic validation to `422`,
`:duplicate_id`, `:duplicate_path`, `:owned_by_another_note`, and `:stale` to
`409`, and storage/internal failures to `500`.

- [x] **Step 3: Add note-relative content routes before `/:id`**

```elixir
get "/gao_notes/:note_id/attachments/*path",
    GaoNoteAttachmentContentController,
    :show
```

`GSMLG.Web.GaoNoteAttachmentContentController` serves the authenticated public
API route. `GSMLG.AdminWeb.GaoNoteAttachmentContentController` serves both the
admin bearer API route and the admin-session browser route.

- [x] **Step 4: Serve bounded raw content**

Both content controllers resolve canonical paths through the note-scoped
context, parse zero or one HTTP byte range with `GSMLG.GaoNote.ByteRange`, and
read storage in inclusive blocks of at most 64 KiB. A valid range returns
`206`; malformed, multiple, or unsatisfiable ranges return `416`; the first
storage failure returns a generic `503`; a later failure aborts the partial
response with sanitized telemetry.

Responses use the verified attachment `Content-Type`,
`X-Content-Type-Options: nosniff`, `Accept-Ranges: bytes`, and
`Cache-Control: private, no-store`. Only AVIF, GIF, JPEG, PNG, WebP, and
`text/plain` are inline. Every active or unrecognized MIME type is forced to
`Content-Disposition: attachment`.

Controller-reachable invalid canonical paths, including traversal and encoded
absolute paths, plus missing/cross-note paths return exact `404`. Malformed URI
percent escapes and invalid URI byte sequences are rejected by Phoenix/Plug
before attachment lookup with exact `400`. Public lookup hides soft-deleted
notes; admin lookup falls back to deleted notes.

- [x] **Step 5: Add controller tests**

Cover create/update aggregate payloads, metadata-only reads, authorization,
route ordering, canonical path lookup, exact `400` versus `404` path status,
headers, bounded bytes, soft-deleted public notes, admin recycle-bin access,
and stale-route removal.

- [ ] **Step 6: Prepare scoped verification**

```bash
unbuffer mix test \
  apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_attachment_content_controller_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/gao_note_attachment_content_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/api_error_controller_test.exs
```

Expected result: authenticated note writes and note-relative downloads work,
while references/assets and independent attachment routes return `404`.

### Task 6: Integrate attachments into the note editor

**Files:**
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/index.ex`
- Delete: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/attachment_live/index.ex`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/router.ex`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/admin_menu.ex`
- Modify: `apps/gsmlg_admin_web/assets/js/hooks/clipboard_hook.js`
- Modify: `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs`
- Modify: `apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs`
- Modify: `apps/gsmlg_admin_web/test/gsmlg/admin_web/components/admin_navigation_test.exs`

- [x] **Step 1: Initialize note-owned attachment state**

The note LiveView calls `allow_upload/3`, maintains ordered attachment drafts
and modal state, and maps loaded note metadata into drafts for edit. Existing
IDs are immutable.

- [x] **Step 2: Add staging events**

The implemented modal open/validate/submit flow, upload progress callback,
`cancel_attachment_upload`, and `remove_attachment` mutate socket draft state
only. Uploaded files are copied into the private editor directory and become
trusted `%Plug.Upload{}` values only while building the Save Note aggregate.

- [x] **Step 3: Submit one aggregate**

On save, consume upload entries into `%Plug.Upload{}` values, merge them into
the staged rows, and call:

```elixir
attrs =
  note_params
  |> Map.put("labels", selected_labels)
  |> Map.put("attachments", attachment_payloads)
```

Create and update use the same attachment payload builder. On errors, retain
the staged rows and upload errors.

- [x] **Step 4: Render the integrated attachment editor**

Place the attachment panel below `<.dm_markdown_input>`. Render:

- New ID, path, MIME, description, file, and text inputs.
- Add action.
- Existing cards with immutable ID and editable path/description.
- MIME read-only unless replacement bytes are staged.
- Download, Replace, Edit text, Copy Markdown link, and Remove actions.
- Responsive stacked fields on narrow viewports.

Keep Save and Cancel at the top.

- [x] **Step 5: Rewrite Markdown URLs on note show**

Rewrite only parsed link and image destinations that match a known canonical
attachment path beginning with `./` to:

```text
/gao_notes/notes/:note_id/attachments/<encoded path>
```

Unknown paths, traversal destinations, absolute URLs, anchors, and inline or
fenced code content remain unchanged. The displayed Markdown link text is not
modified.

- [x] **Step 6: Reuse clipboard behavior**

The existing `Clipboard` hook reads `data-clipboard-text`, uses
`navigator.clipboard.writeText/1` with its fallback, and displays copy
feedback. Attachment cards provide generated Markdown:

```markdown
[filename](./path)
![description](./path)
```

- [x] **Step 7: Remove standalone surfaces**

Delete both standalone attachment routes, delete `AttachmentLive.Index`, remove
the Note Attachments menu item, and remove list/show navigation to the old
pages.

- [x] **Step 8: Rewrite LiveView and navigation tests**

Cover text and file staging, edit metadata, replacement, lazy UTF-8 editing,
remove, save, cancel, error-state retention, Markdown links, download links,
mobile-safe markup, and absence of old routes/menu entries.

- [ ] **Step 9: Prepare scoped verification**

```bash
unbuffer mix test \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/components/admin_navigation_test.exs
```

Expected result: attachments are managed only inside note create/edit and old
attachment pages are absent.

### Task 7: Align MCP transport tests and documentation

**Files:**
- Modify: `apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_mcp_controller_test.exs`
- Modify: `apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/gao_note_mcp_controller_test.exs`
- Delete: `docs/gao_note/implementation.md`
- Create: `docs/gao_note_attachments.md`
- Modify: `docs/README.md`
- Modify: `note_chunking.md`
- Modify: `docs/superpowers/specs/2026-07-18-gao-note-attachments-design.md`
- Delete superseded July 13/14 GaoNote attachment design and plan artifacts

- [x] **Step 1: Update MCP transport assertions**

Assert readonly tools contain only search, get, and label-setting reads. Assert
admin tools add note create/update/delete and label mutation, with no
attachment-specific operations.

Assert create has optional `attachments` and update requires it.

- [x] **Step 2: Remove obsolete attachment documentation**

Replace role/caption/alt-text/position/visibility/storage-file-ID examples with
the approved `id`, `path`, `mime`, `description`, `content`, and
`content_base64` contract.

Document metadata-only reads, global IDs, full-list update semantics, MIME
verification, note-relative downloads, soft-delete retention, and purge jobs.

- [ ] **Step 3: Prepare the complete scoped verification command**

Run only after explicit user authorization:

```bash
unbuffer mix test \
  apps/gsmlg_gao_note/test \
  apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_attachment_content_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_mcp_controller_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/gao_note_attachment_content_controller_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/gao_note_mcp_controller_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/components/admin_navigation_test.exs \
  apps/gsmlg_storage/test/gsmlg/storage_test.exs \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/workers/storage_file_purge_worker_test.exs
```

Expected result: all scoped tests pass with no references to independent
attachment CRUD or obsolete attachment fields.

- [ ] **Step 4: Prepare static quality checks**

Run only after explicit user authorization:

```bash
unbuffer mix format --check-formatted
unbuffer mix compile --warnings-as-errors
```

Expected result: formatting is clean and compilation emits no warnings.
