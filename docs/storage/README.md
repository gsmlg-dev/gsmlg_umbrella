# S3 storage and the admin browser

S3 is the source of file bytes, file metadata and directory markers. Runtime
storage operations do not read or write the legacy `storage_files` or
`storage_folders` tables. The original [storage PRD](prd.md) describes the
superseded SQL catalog design.

## Browsing and configuration changes

Opening `/storage`, refreshing the page or pressing Refresh performs a new
paginated S3 `ListObjectsV2` scan. The complete successful snapshot is cached in
the authenticated user's session process and shared by their browser tabs.
Folder navigation, search and pagination use that snapshot. Closing the session
discards it.

The browser displays objects uploaded outside GSMLG as well as managed files,
using their exact S3 keys, sizes and modification times. Empty folders are real
zero-byte objects with keys ending in `/`. The `.gsmlg-storage/` namespace is
reserved and hidden from the browser.

A failed scan retains the last successful snapshot from the same backend and
displays an error. A bucket, endpoint, region or credential change invalidates
the old snapshot. Late results cannot replace a newer refresh or populate the
new bucket with the previous bucket's objects. Detail links and mutations carry
the backend identity; stale actions require refreshing the listing.

Storage → S3 Configuration still persists connection settings separately.
GaoNote's configurable storage path remains in TOML and defaults to `gaonote`.
Changing either setting moves subsequent operations to the new location; it
does not copy existing objects.

## Managed identities and cleanup

Managed file metadata is stored at
`.gsmlg-storage/objects/<storage-file-uuid>.json`. Each versioned manifest retains
the original UUID, object key, filename, verified MIME type, size, checksum,
metadata, variants, uploader, lifecycle status and timestamps. UUID URLs and
GaoNote attachment references remain stable. Files uploaded externally do not
need a manifest to appear in the browser.

Uploads write a recoverable `processing` manifest before uploading bytes, then
mark the manifest `active`. The cleanup worker reads S3 manifests, recovers
expired intents, retries image variants and purges retained tombstones. Its
bounded batches rotate between objects so protected or failed entries cannot
starve later work. No SQL inventory or committed Styx recovery job is required
to discover an interrupted upload.

GaoNote note/attachment relationships, sync pins, leases and business
transactions remain in PostgreSQL. Shared advisory locks protect managed files
from deletion while an attachment or sync pin references them. Browser deletion
removes S3 objects immediately; managed original deletion includes variants and
leaves a recoverable tombstone if S3 deletion fails. Internal `Storage.delete/1`
continues to soft-delete for retention-based cleanup.

## Upgrading an existing installation

Back up the database and bucket, stop old application writers, and run the new
release's existing migration command before starting the new application:

```sh
./bin/gsmlg_umbrella eval 'GSMLG.Release.migrate()'
```

The command first exports legacy file/folder metadata to S3 using the configured
bucket and credentials. It preserves the original UUIDs, keys and timestamps,
verifies active object sizes, and resumes without overwriting an existing file
manifest. Missing active bytes, conflicting keys, malformed manifests or S3
errors stop the export. Only a complete export writes
`.gsmlg-storage/migrations/catalog-v1.json`.

The subsequent SQL migration removes only the attachment and sync-pin foreign
keys pointing to `storage_files`; it retains the old tables and data. Those
tables are historical backup/export sources after the upgrade. New files exist
only in S3, so rolling back to a release that needs SQL file records also needs a
matching database/bucket restore. Switching to a different bucket requires
copying both payloads and manifests to retain existing attachment access.

The runtime needs S3 list, read, write and delete access for the configured
bucket, including the reserved manifest namespace. This document describes the
upgrade procedure; it does not establish that a production export or deployment
has run.
