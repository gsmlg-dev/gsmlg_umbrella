# GaoNote Note-Owned Attachments Design

Date: 2026-07-18

Status: Implemented; scoped validation not run

Canonical contract: [GaoNote Note-Owned Attachments](../../gao_note_attachments.md)

## Summary

GaoNote attachments become part of the note aggregate and follow the workflow
used by `/data/development/gsmlg-opt/agent-note/`.

Users create, edit, replace, and remove attachments inside the note form. Note
create and update requests carry the complete attachment list. Attachment
metadata is returned with notes, while attachment bytes remain in
`GSMLG.Storage` and are downloaded through note-relative content routes.

This is a hard-breaking refactor. Independent attachment CRUD, admin pages,
routes, MCP tools, resources, and obsolete metadata fields have been removed
without compatibility shims.

## Goals

- Make attachments owned and saved by a note.
- Keep attachment bytes in `GSMLG.Storage`.
- Use caller-supplied, globally unique attachment IDs.
- Support Markdown links such as `[data](./data.txt)`.
- Reconcile the complete attachment list during note updates.
- Return attachment metadata with notes without embedding bytes in reads.
- Retain attachment bytes while a note is soft-deleted.
- Delete attachment bytes after removal or permanent note deletion.
- Use the same attachment contract in the admin UI, public API, and MCP.

## Non-Goals

- Sharing one storage object between multiple notes or attachments.
- Attaching a pre-existing storage object.
- Independent attachment CRUD outside note create and update.
- Returning attachment bytes inside note read responses.
- Preserving current attachment rows or obsolete attachment metadata.
- Adding a GaoNote-specific attachment size limit.

## Selected Architecture

The note is the aggregate root. PostgreSQL stores attachment identity and
metadata, while `GSMLG.Storage` stores the bytes. Every GaoNote attachment owns
one dedicated storage object.

The database and object store cannot participate in one atomic transaction.
The write flow therefore stages new objects before the database transaction,
keeps old objects until the transaction commits, and schedules obsolete objects
for retryable deletion after commit.

No GenServer or other long-lived process is required. Validation and
reconciliation are plain context functions. Retryable object deletion uses the
application's existing background-job infrastructure.

## Data Model

Each attachment row stores its caller-supplied ID, owning note, private storage
link, canonical path, verified MIME, description, and timestamps.

Required constraints:

- Primary key on the globally unique attachment ID.
- Index on the owning note.
- One attachment per private storage object.
- Unique canonical path within each note.
- Cascading attachment-row deletion when the note is permanently deleted.

Remove these fields:

- `role`
- `caption`
- `alt_text`
- `position`
- `metadata`

The private storage link is never exposed in the public note shape.

## Attachment Identity

- Trim an incoming attachment ID before validation and storage.
- Reject an empty ID.
- IDs are globally unique across all notes.
- An existing ID can only be retained or updated by its owning note.
- Using an ID owned by another note is a conflict.
- IDs are immutable after creation.
- Changing an ID means removing the old attachment and adding a new one.

## Attachment Paths

The stored path is canonical:

1. Trim surrounding whitespace.
2. Convert backslashes to forward slashes.
3. Remove empty segments and `.` segments.
4. Prefix the result with `./`.

Reject paths that:

- Are empty after normalization.
- Begin at a Unix or Windows filesystem root.
- Contain a Windows drive prefix.
- Contain a URL scheme.
- Contain any `..` segment.

Normalized paths must be unique within a note. For example,
`./files//data.txt` and `files/./data.txt` conflict because both normalize to
`./files/data.txt`.

## MIME Verification

The request must include `mime`, but it is not trusted.

- Detect MIME from the attachment bytes using the storage layer's content
  detector.
- Reject a submitted MIME that conflicts with the detected MIME.
- Store and return the detected canonical MIME.
- If detection can only establish `application/octet-stream`, the submitted
  MIME must also be `application/octet-stream`.
- Existing attachments that retain their bytes retain their verified MIME.
- Changing MIME without replacing bytes is rejected unless the verified value
  is unchanged.

## Note Write Contract

### Create

`attachments` is optional and defaults to an empty list.

### Update

`attachments` is required and is the complete desired attachment list.
Submitting `[]` removes every attachment from the note.

### Attachment Input

```json
{
  "id": "deployment-data",
  "path": "./data.txt",
  "mime": "text/plain",
  "description": "Deployment values",
  "content": "PORT=4111"
}
```

Each attachment accepts:

| Field | Required | Behavior |
| --- | --- | --- |
| `id` | Yes | Globally unique attachment identity |
| `path` | Yes | Canonical note-relative path |
| `mime` | Yes | Verified against bytes |
| `description` | No | Defaults to `""` |
| `content` | Conditional | UTF-8 attachment body |
| `content_base64` | Conditional | Strict padded Base64 attachment body |

Content rules:

- A new public attachment input requires `content`, `content_base64`, or both.
- An existing attachment may omit both fields to retain its storage object.
- Supplying content for an existing attachment replaces its storage object.
- The aggregate domain and public HTTP note-write input accept both content
  forms only when their decoded bytes are identical.
- The MCP schema permits at most one content form.
- A trusted `%Plug.Upload{}` is an internal admin-only alternative and is
  mutually exclusive with both content forms.
- An invalid or unpadded Base64 value is rejected.
- Missing IDs from an update are removed from the note.

Example note update:

```json
{
  "title": "Deployment",
  "content": "See [deployment data](./data.txt).",
  "labels": {
    "type": "runbook"
  },
  "attachments": [
    {
      "id": "deployment-data",
      "path": "./data.txt",
      "mime": "text/plain",
      "description": "Deployment values"
    }
  ]
}
```

The omitted content fields retain the existing bytes for `deployment-data`.

## Note Read Contract

Note reads return attachment metadata only:

```json
{
  "id": "deployment-data",
  "path": "./data.txt",
  "mime": "text/plain",
  "description": "Deployment values",
  "content_url": "/api/gao_notes/NOTE_ID/attachments/data.txt"
}
```

Do not return:

- `content`
- `content_base64`
- Internal storage identifiers, keys, or provider URLs

Any public surface that returns a complete note uses this metadata shape.
Queries preload attachments to avoid per-note attachment queries.

## Write and Reconciliation Flow

The context performs these steps:

1. Normalize and validate the complete note and attachment input.
2. Load existing attachments for the note in one query.
3. Reject duplicate payload IDs, duplicate normalized paths, and IDs owned by
   another note.
4. Decode and verify every new or replacement attachment.
5. Upload new storage objects without modifying old objects.
6. Run one database transaction that updates the note, upserts attachment
   metadata, removes missing attachment rows, and inserts cleanup jobs for
   obsolete storage objects.
7. If the transaction fails, delete newly uploaded objects on a best-effort
   basis and leave the note unchanged.
8. If the transaction commits, cleanup jobs delete obsolete objects with
   retries.

Replacement uploads always create a new storage object. Existing storage
objects are never overwritten in place.

## Deletion Lifecycle

### Removing an attachment

- Saving the note without the attachment removes its metadata row.
- The transaction records a retryable cleanup job for its storage object.

### Soft-deleting a note

- Keep all attachment metadata and storage objects.
- Public note and attachment routes treat the note as absent.
- Restoring the note makes the existing attachments available again.

### Permanently deleting a note

- Capture all linked storage objects.
- Insert retryable cleanup jobs.
- Permanently delete the note and cascade-delete attachment rows in the same
  database transaction.

An admin attachment route may serve attachments for a soft-deleted note from
the recycle-bin context. Public routes may not.

## Raw Content Routes

Authenticated raw routes exist on both web surfaces:

```text
GET /api/gao_notes/:note_id/attachments/*path
GET /gao_notes/notes/:note_id/attachments/*path
```

Route behavior:

- The public API route requires a user access token and serves active notes
  only.
- The admin browser route requires an admin session and may serve active or
  soft-deleted notes.
- The admin endpoint also exposes the `/api/...` route behind admin bearer
  authentication and may serve active or soft-deleted notes.
- Normalize the wildcard path and resolve it within the specified note.
- Return `404` for controller-reachable invalid canonical paths, absent paths,
  deleted public notes, and path ownership mismatches.
- Let Phoenix/Plug reject malformed percent escapes and invalid URI byte
  sequences before controller lookup with `400`.
- Accept no range or one `Range: bytes=...` value. Multiple, malformed, or
  unsatisfiable ranges return `416` with `Content-Range: bytes */SIZE`.
- Return `206`, `Content-Range`, and `Accept-Ranges: bytes` for a valid range.
- Read from `GSMLG.Storage` in bounded blocks of at most 64 KiB.
- Set the verified `Content-Type`.
- Inline only AVIF, GIF, JPEG, PNG, WebP, and plain text. Force every active or
  unrecognized MIME type, and every type outside that conservative allowlist,
  to download with `Content-Disposition: attachment`.
- Set `X-Content-Type-Options: nosniff`.
- Set `Cache-Control: private, no-store`.
- Never expose a direct provider URL.

Route declarations must precede conflicting dynamic note routes.

## Markdown Resolution

Only parsed Markdown link and image destinations matching a known canonical
attachment path on the owning note are rewritten to that note's authenticated
attachment route.

Examples:

```markdown
[Deployment data](./data.txt)
![Network topology](./images/network.png)
```

Unknown paths, traversal destinations, absolute URLs, anchors, and inline or
fenced code content remain unchanged.

Markdown output is sanitized through the local AST allowlist before it is
marked safe. The local workaround for
[`duskmoon-dev/duskmoon-elements#70`](https://github.com/duskmoon-dev/duskmoon-elements/issues/70)
remains required and must not be described as resolved.

## Admin UI

Attachments appear below Markdown content inside note create and edit forms.
Save and Cancel remain at the top of the page.

### Add attachment

The staging form contains:

- ID
- Path
- MIME
- Description
- File picker
- Text-content input
- Add action

Selecting a file defaults:

- ID to a collision-free value derived from the filename.
- Path to `./filename`.
- MIME to the browser-reported value for convenience only.

Server-side MIME verification remains authoritative.

### Existing attachment card

Each card displays:

- Immutable ID
- Editable path
- Verified MIME
- Editable description
- Download
- Replace file
- Edit text when the current bytes are valid UTF-8
- Copy Markdown link
- Remove

Existing content is loaded only when the user downloads it or opens text
editing. The normal note edit load remains metadata-only.

### Staging behavior

- Adding, editing, replacing, or removing an attachment changes form state
  only.
- New LiveView uploads remain temporary until Save Note.
- Save Note submits one complete note aggregate.
- Cancel discards staged state and makes no storage changes.
- A failed save keeps the staged form and shows field-level errors.
- Temporary editor directories are service-owned mode `0700`; staged files and
  ownership markers are mode `0600`.
- Save, cancel, explicit removal, and editor-process exit clean private staged
  files. A stale sweep removes inactive editor directories after seven days.
- Mobile layouts stack fields and actions vertically.

`Plug.Upload` is a trusted internal admin implementation detail after this
private staging step. It is mutually exclusive with `content` and
`content_base64` and is not accepted by public API or MCP schemas.

### Removed UI

Remove:

- The global Note Attachments menu.
- The global attachment page.
- Per-note standalone attachment pages.
- Attach-existing-storage-file controls.

Note show pages render attachment metadata and authenticated download links.

## Public API

The existing note create and update endpoints adopt the note write contract.
The existing note read endpoints adopt the metadata-only read contract.

No independent attachment CRUD endpoints remain. The only attachment-specific
HTTP operation is authenticated raw content download through the owning note.

Error mapping:

| Condition | HTTP status |
| --- | --- |
| Malformed request envelope, missing required `attachments`, non-list `attachments`, unknown top-level or nested fields, or malformed Base64 | `400 Bad Request` |
| Semantic attachment, path, MIME, or content validation | `422 Unprocessable Entity` |
| Attachment ownership conflict | `409 Conflict` |
| Missing or inaccessible note or attachment path | `404 Not Found` |
| Missing authentication | `401 Unauthorized` |
| Authenticated but unauthorized | `403 Forbidden` |
| Storage or internal failure | `500 Internal Server Error` |

## MCP

MCP exposes aggregate note operations only.

- Readonly tools are note search/get and label-setting reads.
- Admin adds note create/update/delete and label-setting/label mutations.
- Note create accepts optional `attachments`.
- Note update requires the complete `attachments` list.
- Tool and nested attachment schemas reject unknown fields.
- Note resources return metadata-only attachment objects.
- No attachment-specific tools or resources are advertised.

`content_url` is returned for clients that can access the authenticated HTTP
surface. MCP does not return attachment bytes or private storage identifiers.

## External Indexing Boundary

Chunking and embedding remain an external service contract documented in
[`note_chunking.md`](../../../note_chunking.md). GaoNote has no local chunk
table. That indexing service is separate from attachment storage and does not
receive attachment metadata or bytes through this contract.

## Size and Memory Policy

GaoNote adds no attachment-specific size limit.

The following existing limits still apply:

- Phoenix request-body limits.
- LiveView upload and transport limits.
- MCP transport limits.
- Reverse-proxy limits.
- Storage-provider limits.

Raw downloads use bounded 64 KiB storage reads. JSON and MCP Base64 writes
remain subject to their transport limits and may require in-memory decoding;
the design does not claim truly unbounded JSON uploads.

## Migration Strategy

This is a destructive development migration:

1. Drop the current `gao_note_attachments` table.
2. Recreate it with the selected schema and constraints.
3. Do not backfill old rows.
4. Remove obsolete schema fields and context operations.
5. Remove obsolete routes, UI, MCP surfaces, presenters, and tests.

Existing development attachment objects may be orphaned by the destructive
schema reset and may be removed with the development storage reset. No
production data migration is required.

## Acceptance Tests

### Domain and storage

- Create a note without attachments.
- Create text and binary attachments.
- Accept valid `content` and strict padded `content_base64`.
- Accept both content fields when bytes match.
- Reject both content fields when bytes differ.
- Verify MIME and reject mismatches.
- Normalize valid relative paths.
- Reject absolute, URL, drive, and traversal paths.
- Reject duplicate normalized paths.
- Reject duplicate payload IDs.
- Reject a global ID owned by another note.
- Retain bytes when an existing ID omits content.
- Replace bytes without overwriting the old storage object in place.
- Add, edit, replace, retain, and remove attachments in one update.
- Leave the note unchanged when upload or database work fails.
- Clean staged objects after transaction failure.
- Retry deletion of obsolete objects after commit.
- Retain attachments through soft delete and restore.
- Delete attachment objects after permanent purge.

### HTTP

- Return metadata-only attachments in note responses.
- Never expose private storage identifiers, keys, or attachment bytes in note
  responses.
- Stream public and admin attachment downloads.
- Enforce note authorization.
- Hide soft-deleted notes on public routes.
- Return verified content headers and `nosniff`.
- Resolve Markdown `./path` links and images.
- Reject traversal and cross-note path access.
- Confirm independent attachment CRUD routes no longer exist.

### MCP

- Expose the selected attachment input schema on note create and update.
- Require the attachment list on note update.
- Return metadata-only attachments from complete note reads.
- Remove independent attachment tools and resources.
- Map validation and global-ID conflicts correctly.

### Admin LiveView

- Stage a new text attachment.
- Stage a file upload.
- Edit path and description.
- Replace file content.
- Lazily edit valid UTF-8 content.
- Copy the correct Markdown path.
- Remove an attachment.
- Save all staged changes with the note.
- Cancel without changing storage.
- Preserve staged state after validation failure.
- Confirm removed attachment menus and pages are absent.

## Completion Criteria

The redesign is complete when:

- Notes own their attachment lifecycle on every supported surface.
- The schema contains only the selected attachment fields.
- Note create and update reconcile complete attachment lists.
- Reads return metadata only.
- Raw downloads and Markdown-relative paths work with authorization.
- Soft delete retains files and permanent purge schedules deletion.
- Independent attachment CRUD no longer exists.
- Scoped domain, API, MCP, and admin validation remains pending until it is
  separately authorized.
