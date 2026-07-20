# GaoNote MCP Standalone Attachment Operations

Date: 2026-07-20
Status: Approved

## Goal

Give GaoNote MCP clients independent attachment operations without requiring a
complete note update or transferring unchanged attachment content.

Initial attachments remain part of note creation. After creation, attachment
changes use dedicated MCP tools.

## MCP Contract

### `gao_note.create_note`

`attachments` remains an optional input. Each initial attachment contains:

- `id`
- `path`
- `mime`
- `description`
- Exactly one of `content` or `content_base64`

### `gao_note.update_note`

Remove `attachments` from the input schema and dispatch path. Updating note
fields or labels must not modify attachments.

### `gao_note.get_note`

Return attachment metadata with the note:

- `id`
- `path`
- `mime`
- `description`
- Storage-independent size and timestamp fields already exposed by the
  presenter

Never return attachment content from this tool.

### `gao_note.put_attachment`

Replace an attachment that already belongs to a note.

Required inputs:

- `note_id`
- `attachment_id`
- `path`
- `mime`
- `description`
- `update_content`

Content rules:

- When `update_content` is `false`, reject `content` and `content_base64`.
- When `update_content` is `false`, the submitted MIME must equal the existing
  verified MIME.
- When `update_content` is `true`, require exactly one of `content` or
  `content_base64`.
- When `update_content` is `true`, verify MIME from the replacement bytes using
  the existing attachment validation path.

Identity rules:

- `attachment_id` is immutable.
- The attachment must already exist and belong to `note_id`.
- This tool never creates or transfers an attachment.
- A globally existing attachment owned by another note must not be modified.

The metadata and optional replacement content are committed atomically. The
tool returns attachment metadata without content.

### `gao_note.delete_attachment`

Required inputs:

- `note_id`
- `attachment_id`

Delete only the identified attachment when it belongs to the identified note.
The operation permanently removes its metadata and schedules the associated S3
object for deletion. There is no attachment restore operation.

### `gao_note.get_attachment_with_content`

Required inputs:

- `note_id`
- `attachment_id`

Return all attachment metadata and:

- `content_base64`

Content is always Base64 encoded, including UTF-8 text. This tool has the same
MCP access level as `gao_note.get_note`. Mutation tools remain admin-only.

## Domain Design

Add dedicated attachment operations to the GaoNote context and attachment
service. MCP handlers call the context directly; they do not make loopback HTTP
requests.

Every operation must:

1. Load and lock the note and attachment where mutation requires it.
2. Verify that the attachment belongs to the supplied note.
3. Preserve the immutable attachment ID and note ownership.
4. Reuse the existing canonical-path, MIME verification, S3 staging, cleanup,
   and purge behavior.
5. Use the existing actor and GaoNote logging conventions.

The existing complete-list reconciliation remains available to note creation
and non-MCP callers that still require it. MCP note updates stop using it.

## Error Behavior

Return existing MCP error shapes for:

- Unknown note
- Unknown attachment
- Attachment owned by another note
- Invalid canonical path
- MIME mismatch without a content update
- Missing or ambiguous replacement content
- Base64 decoding failure
- S3 read, write, or deletion scheduling failure

Failures before commit must leave the existing attachment metadata and storage
reference unchanged. Failed replacement storage must use the existing cleanup
path.

## Compatibility

This is a hard-breaking MCP schema change:

- Remove `attachments` from `gao_note.update_note`.
- Add the three standalone attachment tools.
- Do not add compatibility aliases or silently translate old update payloads.
- Keep initial attachment creation in `gao_note.create_note`.

No database migration is required.

## Acceptance Tests

- Tool listing exposes the three new tools with minimal, tool-specific schemas.
- `update_note` no longer advertises or accepts `attachments`.
- Note creation still supports initial attachments.
- `get_note` exposes attachment metadata but never content.
- Metadata-only put preserves bytes and verified MIME.
- Content-replacing put replaces bytes and metadata atomically.
- Put rejects unknown, transferred, or mismatched attachments.
- Put enforces the `update_content` content-field rules.
- Content retrieval returns metadata and exact bytes as Base64.
- Delete removes only the selected note attachment and schedules storage purge.
- Read-only MCP exposes `get_attachment_with_content`; mutation tools remain
  admin-only.
