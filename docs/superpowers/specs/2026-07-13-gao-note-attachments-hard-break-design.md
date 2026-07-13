# GaoNote Attachments Hard-Break Design

## Objective

Make `Attachment` the only subordinate file concept in GaoNote. Remove the
`Reference` feature completely and replace every GaoNote-specific use of
`Asset` with `Attachment` across persistence, Elixir modules, admin UI, public
HTTP APIs, MCP tools and resources, documentation, and tests.

This is an intentional hard break. No compatibility aliases, legacy routes,
legacy MCP names, or deprecated response keys will remain.

## Final Domain Model

A note contains note data, labels, and attachments:

```text
Note
  id
  title
  description
  labels
  content
  created_at
  updated_at
  deleted_at
  attachments[]
```

Each attachment contains:

```text
Attachment
  id                 globally unique attachment UUID
  note_id
  storage_file_id
  description        defaults to an empty string
  path               note-relative path such as ./data.txt
  mime
  content
  role
  caption
  alt_text
  position
  metadata
  created_at
  updated_at
```

The attachment `path` is unique within a note. Markdown in the note uses the
same path, so `./data.txt` resolves to the attachment whose path is
`./data.txt`.

`Reference` is not part of the final model. URLs that matter to a note belong
in Markdown content or in an attached file.

## Persistence and Migration

The final table is `gao_note_attachments`. It retains the existing asset fields
and constraints, renamed to attachment terminology.

Fresh databases will:

- create `gao_note_attachments` directly;
- never create `gao_note_references`;
- create attachment indexes with `gao_note_attachments_*` names;
- use the GaoNote storage type `attachment` for new uploads.

Existing development databases will use an idempotent compatibility migration
that:

1. drops `gao_note_references` when it exists;
2. renames `gao_note_assets` to `gao_note_attachments` when the old table
   exists and the new table does not;
3. renames or recreates old asset indexes under attachment names;
4. preserves all existing attachment rows and storage-file relationships;
5. updates `storage_files` rows whose tenant is `gao_note` and whose type is
   `asset` to use type `attachment`.

The compatibility migration is safe on a fresh database where the final table
already exists. Its down migration is intentionally unsupported because this
is a hard break.

## Elixir Domain API

The schema module becomes `GSMLG.GaoNote.Attachment` and uses
`gao_note_attachments`.

`GSMLG.GaoNote.Note` exposes:

```elixir
has_many(:attachments, Attachment, foreign_key: :note_id)
```

The GaoNote context exposes these attachment operations:

```text
list_attachments/1
list_all_attachments/1
get_attachment/1
change_attachment/2
attach_existing_file/4
upload_attachment/4
update_attachment/3
detach_attachment/2
```

All `Reference` functions and all `Asset`-named functions are deleted. Normal
queries exclude attachments whose parent note is logically deleted. Permanent
note deletion continues to remove attachments through the database foreign
key.

## Serialization Contract

The note response key is always `attachments`. The old keys `assets` and
`references` are never emitted.

Attachment JSON uses:

```json
{
  "id": "attachment_uuid",
  "description": "",
  "path": "./data.txt",
  "mime": "text/plain",
  "content": "example content",
  "storage_file_id": "storage_file_uuid",
  "role": "attachment"
}
```

List and search responses must not report `attachments: []` merely because the
association was not preloaded. They either preload attachment metadata or use
an explicit summary representation that does not claim the note has no
attachments.

Storage visibility remains authoritative. Public HTTP and read-only MCP
surfaces do not inline private attachment content or expose a private file URL.
Admin surfaces may access private attachments.

## Public HTTP API

The retained routes are:

```text
GET /api/gao_notes
GET /api/gao_notes/:id
GET /api/gao_notes/label_settings
GET /api/gao_notes/:id/attachments
```

The following routes are removed:

```text
GET /api/gao_notes/:id/references
GET /api/gao_notes/:id/assets
```

The attachments endpoint returns attachment JSON and respects the same public
storage visibility rules as note serialization.

## MCP Contract

Read-only MCP exposes:

```text
gao_note.list_attachments
```

Admin MCP additionally exposes:

```text
gao_note.attachments.attach_existing
gao_note.attachments.upload_base64
gao_note.attachments.update
gao_note.attachments.detach
```

Mutation tools use `attachment_id`, not `asset_id`.

MCP resources become:

```text
gaonote://notes/{id}/attachments
gaonote://attachments/{attachment_id}
```

All `gao_note.references.*`, `gao_note.assets.*`, `/references`, `/assets`, and
asset resource definitions are deleted from both servers and the MCP admin
inspector.

## Admin UI

The GaoNote menu contains one attachment entry:

```text
Attachments -> /gao_notes/attachments
```

The routes are:

```text
/gao_notes/attachments
/gao_notes/notes/:id/attachments
```

The LiveView module becomes
`GSMLG.AdminWeb.GaoNoteLive.AttachmentLive.Index`. It supports global listing,
note-specific listing, upload, attaching an existing storage file, metadata
updates, and detach.

The old Reference page, Asset page, menu items, links, active-menu IDs, labels,
flash messages, DOM IDs, and headings are removed or renamed. Note list and
detail actions link only to Attachments.

When a LiveView upload does not provide `path`, the default path is derived
from the client filename, not the temporary upload filename.

## Error Handling and Security

- Unknown note and attachment IDs return the existing not-found behavior.
- Attachment path and uniqueness errors return changesets through context,
  LiveView, HTTP, and MCP boundaries.
- Attachment mutations require an active parent note.
- File MIME detection continues to use storage content detection rather than a
  client-provided content type.
- Public serialization enforces storage visibility before reading attachment
  content.
- Hard-deleted references are intentionally unrecoverable.

## Test Changes

Tests will be updated as a hard break:

- delete Reference schema, context, controller, LiveView, MCP, and route tests;
- rename Asset fixtures and assertions to Attachment;
- cover attachment create, list, update, detach, path uniqueness, default
  description, and default client-filename path;
- verify note serialization uses `attachments` and never `assets` or
  `references`;
- verify public APIs and read-only MCP do not expose private content;
- verify admin routes and menu show Attachments only;
- verify MCP tool schemas use `attachment_id` and attachment names;
- verify soft-deleted notes do not expose mutable attachments;
- verify the fresh migration shape and exercise the compatibility migration
  against an old `gao_note_assets` table fixture.

## Acceptance Criteria

- No GaoNote production module, route, response, MCP surface, admin label, or
  test refers to the removed Reference or Asset concepts.
- The final database contains `gao_note_attachments` and does not contain
  `gao_note_assets` or `gao_note_references`.
- Existing asset rows survive as attachments after migration.
- The admin sidebar shows Attachments and no Reference or Asset entry.
- Note-specific and global attachment pages load and manage attachments.
- Public HTTP and MCP contracts expose attachment terminology only.
- The GaoNote test suites pass with the new hard-break contract.
