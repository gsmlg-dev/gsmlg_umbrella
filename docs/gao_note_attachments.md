# GaoNote Note-Owned Attachment Contract

Status: Implemented. Scoped validation has not been run.

This is the canonical contract for GaoNote attachments across the public API,
admin UI, MCP, and raw content routes.

## Aggregate Write Contract

A note owns its complete attachment list.

- Note create accepts an optional `attachments` list and defaults it to `[]`.
- Note update requires `attachments`; it is a full replacement list.
- An empty update list removes every attachment from the note.
- Omitting an existing attachment ID removes that attachment.
- There are no independent attachment mutation endpoints, tools, resources, or
  admin pages.

Each attachment input accepts only:

| Field | Rule |
| --- | --- |
| `id` | Required caller-supplied ID; globally unique and immutable |
| `path` | Required note-relative path; canonical stored form begins with `./` |
| `mime` | Required claimed MIME; server verification is authoritative |
| `description` | Optional attachment description; defaults to `""` |
| `content` | Optional UTF-8 input bytes |
| `content_base64` | Optional strict padded Base64 input bytes |

Paths are normalized by trimming whitespace, converting `\` to `/`, dropping
empty and `.` segments, and adding `./`. Empty paths, roots, drive prefixes,
URL schemes, and `..` are rejected. Canonical paths must be unique within one
note.

A new ID requires bytes from `content` or `content_base64`. A retained ID may
omit both to reuse its existing bytes. Supplying bytes for a retained ID
replaces its storage object. The aggregate domain and public HTTP note-write
input may provide both content forms only when they decode to identical bytes;
the strict MCP schema permits at most one.

New and replacement objects are staged before the note transaction. A failed
write cleans newly staged objects on a best-effort basis and leaves existing
rows and objects unchanged. After a successful write, removed and replaced
objects are scheduled for retryable cleanup.

`Plug.Upload` is a trusted internal admin implementation detail after private
LiveView staging. It is mutually exclusive with both `content` and
`content_base64` and is not part of the public API or MCP schema.

Aggregate and public HTTP write errors use these status classes:

- `400 Bad Request` for a malformed request envelope, a missing required
  `attachments` list, non-list `attachments`, unknown top-level or nested
  fields, or malformed Base64.
- `422 Unprocessable Entity` for semantic attachment, path, MIME, or content
  validation.
- `409 Conflict` for attachment ownership conflicts.
- `404 Not Found` for an inaccessible note or attachment path.

## MIME and Storage Lifecycle

The submitted MIME is not trusted. GaoNote detects MIME from the bytes, rejects
mismatches, and stores the verified value. Retained bytes retain their verified
MIME; changing MIME requires replacement bytes unless the value is unchanged.

- Soft delete retains attachment metadata and bytes.
- Restore makes the retained attachments active again.
- Permanent delete transactionally schedules retryable storage cleanup before
  deleting the note and its attachment rows.
- Removing or replacing an attachment schedules the same retryable cleanup.

## Read Contract

Complete note reads expose attachment metadata only:

```json
{
  "id": "deployment-data",
  "path": "./files/data.txt",
  "mime": "text/plain",
  "description": "Deployment values",
  "content_url": "/api/gao_notes/NOTE_ID/attachments/files/data.txt"
}
```

Responses do not include attachment bytes, private storage identifiers, keys,
or provider URLs.

## Authenticated Raw Content

| Surface | Route | Authentication | Note visibility |
| --- | --- | --- | --- |
| Public web API | `GET /api/gao_notes/:note_id/attachments/*path` | User access token | Active only |
| Admin browser | `GET /gao_notes/notes/:note_id/attachments/*path` | Admin session | Active and soft-deleted |
| Admin API | `GET /api/gao_notes/:note_id/attachments/*path` on the admin endpoint | Admin bearer token | Active and soft-deleted |

Controller-reachable invalid canonical paths, including traversal, encoded
absolute paths, and NUL-bearing paths, return `404`. Unknown paths, cross-note
paths, and deleted public notes also return `404`.

Malformed URI percent escapes and invalid URI byte sequences are rejected by
Phoenix/Plug before controller lookup and return `400`.

Raw responses:

- Accept no range or one `Range: bytes=...` value.
- Return `206`, `Content-Range`, and `Accept-Ranges: bytes` for a valid range.
- Return `416` for multiple, malformed, or unsatisfiable ranges.
- Read storage in bounded blocks of at most 64 KiB.
- Set the verified `Content-Type`, `Cache-Control: private, no-store`, and
  `X-Content-Type-Options: nosniff`.
- Inline only AVIF, GIF, JPEG, PNG, WebP, and plain text.
- Force every active or unrecognized MIME type, and every type outside that
  conservative allowlist, to download with
  `Content-Disposition: attachment`.

## Admin Editor and Private Staging

Attachment add, metadata edit, replacement, text edit, and removal change only
the LiveView form state until Save Note. Save submits one complete note
aggregate. Cancel discards staged state without changing persisted storage. A
failed save keeps staged rows and field errors.

Temporary editor directories are service-owned mode `0700`. Staged files and
ownership markers are mode `0600`. Save, cancel, explicit removal, and editor
process exit clean private staged files. A stale sweep removes inactive editor
directories after seven days.

Only parsed Markdown link and image destinations matching a known canonical
attachment path are rewritten to the authenticated admin raw route. Unknown
paths, traversal destinations, absolute URLs, anchors, and inline or fenced
code content remain unchanged. Rendered Markdown passes through a local AST
tag, attribute, and URL allowlist before being marked safe.

The local workaround for
[`duskmoon-dev/duskmoon-elements#70`](https://github.com/duskmoon-dev/duskmoon-elements/issues/70)
remains required. This documentation does not claim that upstream issue is
resolved.

## MCP Contract

MCP exposes aggregate note operations only.

- Readonly tools: `gao_note.search`, `gao_note.get`, and
  `gao_note.list_label_settings`.
- Admin adds `gao_note.create_note`, `gao_note.update_note`,
  `gao_note.delete`, `gao_note.create_label_setting`, and
  `gao_note.set_labels`.
- Resources are note, note metadata, and label-setting resources.
- Create has an optional attachment list; update requires the complete list.
- Top-level and nested schemas reject unknown fields.
- Complete note results use the metadata-only presenter shape above.
- `content_url` requires access to the authenticated HTTP surface.
- MCP does not advertise attachment-specific tools or resources.

## External Indexing Boundary

Chunking and embedding remain an external service contract documented in
[`note_chunking.md`](../note_chunking.md). GaoNote has no local chunk table.
That service is separate from attachments and does not receive attachment
metadata or bytes through this contract.
