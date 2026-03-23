# GSMLG.Storage — Product Requirements Document

**Status**: Draft
**Author**: Jonathan
**Date**: 2026-03-19
**Related**: [gsmlg_storage_design.md](./gsmlg_storage_design.md) (Technical Design)

---

## 1. Problem Statement

The GSMLG platform currently has no unified mechanism for storing, managing, and serving user-uploaded files. File handling is ad-hoc across services — some store locally, some reference external URLs, none provide consistent content-type validation, image processing, or a management interface. This creates fragmented data, no audit trail, and no operational visibility into stored assets.

---

## 2. Product Goals

1. **Centralized file storage** — One API for all apps in the umbrella to upload, retrieve, and delete files backed by S3.
2. **Fast, cacheable serving** — Stream files to end users through `gsmlg_web` with proper HTTP caching, achieving CDN-equivalent performance for repeat requests.
3. **Admin management** — Give operators a LiveView interface to browse, upload, inspect, and delete stored files.
4. **Automatic image optimization** — Generate thumbnails and resized variants on upload without manual intervention.
5. **Operational safety** — Prevent content-type spoofing, enforce size limits, soft-delete with recovery window, and clean up orphaned resources automatically.

---

## 3. Users & Consumers

| User | App | Access | Actions |
|------|-----|--------|---------|
| End user (browser) | `gsmlg_web` | Public, read-only | View/download files via `/files/:id` |
| Admin / Operator | `gsmlg_admin_web` | Authenticated | Upload, browse, edit metadata, delete, regenerate variants |
| Internal services | `gsmlg_storage` API | Programmatic | Any app in the umbrella calls `GSMLG.Storage` directly |

---

## 4. Functional Requirements

### 4.1 Upload

| ID | Requirement | Priority |
|----|-------------|----------|
| UP-1 | Accept files from `%Plug.Upload{}`, file path, raw binary, or stream | P0 |
| UP-2 | Detect actual content type via magic bytes (first 8 bytes), not trust client-provided MIME | P0 |
| UP-3 | Validate against configurable allowlist per file type category (avatar, document, attachment) | P0 |
| UP-4 | Reject files exceeding configurable size limit before upload begins | P0 |
| UP-5 | Generate S3 key using `{tenant}/{type}/{yyyy}/{mm}/{uuid}.{ext}` convention | P0 |
| UP-6 | Compute SHA-256 checksum during upload (streamed, not buffered) | P0 |
| UP-7 | Create DB index record with metadata after successful S3 upload | P0 |
| UP-8 | Use S3 multipart upload for files exceeding 5MB chunk threshold | P1 |
| UP-9 | Stream upload without buffering full file in memory | P1 |
| UP-10 | Trigger async variant generation after upload completes | P1 |

### 4.2 Serving (via `gsmlg_web`)

| ID | Requirement | Priority |
|----|-------------|----------|
| SV-1 | Serve files at `GET /files/:id` by streaming from S3 through Phoenix | P0 |
| SV-2 | Serve variants at `GET /files/:id/v/:variant` | P0 |
| SV-3 | Set `Content-Type`, `Content-Length`, `Content-Disposition` headers from DB index | P0 |
| SV-4 | Set `Cache-Control: public, max-age=31536000, immutable` on all responses | P0 |
| SV-5 | Set `ETag` from SHA-256 checksum, respond 304 on `If-None-Match` match | P0 |
| SV-6 | Return 404 for files with `status != "active"` | P0 |
| SV-7 | Support `Range` header for partial content (video, large files) | P1 |
| SV-8 | No authentication required — all active files are publicly accessible | P0 |

### 4.3 Admin Management (via `gsmlg_admin_web`)

| ID | Requirement | Priority |
|----|-------------|----------|
| AM-1 | File browser page with paginated list, filterable by tenant and type | P0 |
| AM-2 | Search files by original filename | P1 |
| AM-3 | Summary stats cards: total files, total size, breakdown by type | P1 |
| AM-4 | Upload page with drag-and-drop zone, multi-file support, progress indication | P0 |
| AM-5 | File detail page showing original + all variant previews side-by-side | P0 |
| AM-6 | Edit file metadata (arbitrary JSON) from detail page | P2 |
| AM-7 | Regenerate variants button on detail page | P1 |
| AM-8 | Delete with confirmation modal — performs soft-delete (status → "deleted") | P0 |
| AM-9 | Bulk select + bulk delete from file browser | P2 |
| AM-10 | Copy public URL (`/files/:id`) to clipboard from detail page | P1 |
| AM-11 | All pages require admin authentication | P0 |

### 4.4 Image Processing

| ID | Requirement | Priority |
|----|-------------|----------|
| IP-1 | Generate configured variants (thumbnail, medium, preview) automatically on image upload | P1 |
| IP-2 | Variant definitions configurable per type category (avatar gets thumb+medium, document gets preview) | P1 |
| IP-3 | Support resize, crop (center), format conversion (→ webp), and quality settings | P1 |
| IP-4 | Process asynchronously — upload returns immediately, variants appear when ready | P1 |
| IP-5 | Store variant metadata (s3_key, size, dimensions) in parent file's `variants` map | P1 |
| IP-6 | Manual regeneration via admin UI or `Storage.regenerate_variants/1` | P1 |
| IP-7 | Use Vix/libvips for memory-efficient streaming processing | P1 |

### 4.5 Deletion & Cleanup

| ID | Requirement | Priority |
|----|-------------|----------|
| CL-1 | `Storage.delete/1` sets `status: "deleted"` (soft delete), does not immediately remove from S3 | P0 |
| CL-2 | Periodic cleanup worker purges S3 objects for files with `status: "deleted"` older than retention window | P1 |
| CL-3 | Cleanup worker retries failed variant generation for active files with empty variants | P1 |
| CL-4 | Orphan detection: identify S3 objects with no corresponding DB record | P2 |
| CL-5 | All deletions remove original + all variant S3 objects | P0 |

---

## 5. Non-Functional Requirements

### 5.1 Performance

| Metric | Target |
|--------|--------|
| Upload latency (< 5MB) | < 2s end-to-end (S3 upload + DB insert) |
| First-byte serving latency | < 100ms (DB lookup + S3 stream initiation) |
| Concurrent uploads | 50+ simultaneous without degradation |
| Concurrent file serves | 1000+ simultaneous (bounded by S3 bandwidth) |
| Memory per upload | < 10MB regardless of file size (streaming, no buffering) |
| Variant generation | < 5s per variant for images under 20MB |

### 5.2 Reliability

| Concern | Approach |
|---------|----------|
| S3 upload failure | Return error, no DB record created, clean state |
| S3 success + DB failure | Attempt S3 cleanup, log orphan if cleanup fails |
| Variant generation crash | File remains active with empty variants, auto-retry via cleanup worker |
| S3 stream failure during serve | Connection closed, client sees partial response |
| S3 delete failure | DB record stays `status: "deleted"`, cleanup worker retries |

### 5.3 Storage

| Parameter | Default | Configurable |
|-----------|---------|:---:|
| Max file size | 5 GB | ✓ |
| Multipart chunk size | 5 MB | ✓ |
| Soft-delete retention | 30 days | ✓ |
| Cleanup worker interval | 1 hour | ✓ |
| Allowed types per category | Per config | ✓ |
| Variant definitions | Per config | ✓ |

### 5.4 Security

- No direct S3 URL exposure — all access proxied through `gsmlg_web`
- Write operations gated behind `gsmlg_admin_web` authentication
- Content-type detection via magic bytes prevents extension spoofing
- Original filenames stored for display only, never used in S3 keys or filesystem paths
- Tenant isolation enforced at the `GSMLG.Storage` API layer — no cross-tenant queries possible

---

## 6. Data Model

### `storage_files` table

| Column | Type | Constraints | Notes |
|--------|------|-------------|-------|
| `id` | `binary_id` (ULID) | PK | |
| `tenant` | `string` | NOT NULL | Scoping key |
| `type` | `string` | NOT NULL | Category: "avatar", "document", etc. |
| `filename` | `string` | NOT NULL | Original upload filename (display only) |
| `s3_key` | `string` | NOT NULL, UNIQUE | Full S3 object key |
| `content_type` | `string` | NOT NULL | Detected MIME type |
| `size` | `bigint` | NOT NULL | Bytes |
| `checksum` | `string` | | SHA-256, used as ETag |
| `metadata` | `map` | | Arbitrary JSON (dimensions, exif) |
| `variants` | `map` | | `%{"thumb" => %{s3_key, size, dimensions}}` |
| `status` | `string` | DEFAULT "active" | active / processing / deleted |
| `uploaded_by` | `string` | | User or system identifier |
| `inserted_at` | `utc_datetime_usec` | | |
| `updated_at` | `utc_datetime_usec` | | |

Indexes: `[tenant, type]`, `[tenant, status]`, `[s3_key]` (unique)

Uses shared `GSMLG.Repo` via config injection.

---

## 7. S3 Key Convention

```
{tenant}/{type}/{yyyy}/{mm}/{uuid}.{ext}          # original
{tenant}/{type}/{yyyy}/{mm}/{uuid}_{variant}.{ext} # variant
```

Keys are immutable — once written, content at a key never changes. This enables aggressive HTTP caching and future CDN integration with zero code changes.

---

## 8. User Flows

### 8.1 Admin Uploads a File

```
Admin navigates to /admin/storage/upload
  → Drags file onto upload zone (or clicks to browse)
  → LiveView shows upload progress bar
  → On completion, Storage.upload/4 executes:
      detect content type → validate → generate key → S3 put → DB insert
  → File appears in browser with status "active"
  → Variant generation starts async
  → Thumbnails appear in file detail within seconds
```

### 8.2 End User Views a File

```
Browser requests GET /files/{id}
  → FileController looks up file in DB
  → If not found or status != "active" → 404
  → Checks If-None-Match header against checksum
  → If match → 304 Not Modified
  → Otherwise: streams from S3, sets headers, responds 200
  → Browser caches for 1 year (immutable)
```

### 8.3 Admin Deletes a File

```
Admin views file detail at /admin/storage/{id}
  → Clicks "Delete" button
  → Confirmation modal appears
  → On confirm, Storage.delete/1 sets status = "deleted"
  → File disappears from browser, returns 404 on public URL
  → CleanupWorker purges S3 objects after retention window
```

---

## 9. Phasing

| Phase | Scope | Depends On |
|-------|-------|------------|
| **1 — Core Library** | `gsmlg_storage` app: S3 module, content-type detection, DB schema, upload/get/stream/delete API, E2E tests | `gsmlg_aws` |
| **2 — Public Serving** | `gsmlg_web` FileController: streaming proxy, caching headers, ETag/304, Range support | Phase 1 |
| **3 — Admin UI** | `gsmlg_admin_web` LiveViews: file browser, upload, detail, delete, stats | Phase 1 |
| **4 — Image Processing** | Vix pipeline, async variant generation, variant serving, admin regeneration | Phase 1+2 |
| **5 — Operations** | Multipart upload, cleanup worker, orphan detection, telemetry | Phase 1 |

Phases 2, 3, 4, 5 can proceed in parallel after Phase 1 is complete.

---

## 10. Out of Scope (Current Version)

- **CDN / CloudFront** — Headers are CDN-ready; adding it is a DNS change. Deferred until bandwidth or latency warrants it.
- **Per-file access control** — All active files are public. Private file support (signed URLs) is a designed escape hatch for a future iteration.
- **Video transcoding** — Only image variants are generated. Video files are stored and served as-is.
- **Oban integration** — Variant generation uses Task.Supervisor. Oban can be introduced later with a localized swap.
- **Direct S3 presigned URLs** — All access goes through Phoenix proxy. Presigned URLs bypass caching and audit controls.
- **Multi-bucket support** — Single bucket per environment. Multi-bucket routing adds complexity without current need.
- **Versioning / history** — Files are immutable (UUID keys). No version chain or rollback. Re-upload creates a new file.

---

## 11. Success Criteria

| Criterion | Measurement |
|-----------|-------------|
| Files uploadable through admin UI | Upload → appears in browser → servable via public URL |
| Serving latency acceptable | p95 first-byte < 200ms under normal load |
| Image variants generated reliably | > 95% of image uploads have all configured variants within 30s |
| No orphaned resources | Cleanup worker reduces orphan count to 0 within 24h of detection |
| Admin can manage files without SSH | Browse, upload, delete, regenerate — all through LiveView |
| Zero data loss on soft-delete | Deleted files recoverable within retention window |

---

## 12. Dependencies

| Dependency | Purpose | Risk |
|------------|---------|------|
| `gsmlg_aws` (umbrella) | S3 client configuration, credentials | Low — existing, stable |
| `ex_aws_s3` | S3 API operations | Low — mature library |
| `vix` / libvips | Image processing | Medium — NIF, requires libvips system package |
| Shared `GSMLG.Repo` | DB index persistence | Low — existing infrastructure |
| S3 bucket provisioning | Storage backend | Requires infra setup per environment |

### Environment Requirements

- **libvips** system package on build and runtime hosts (NixOS: `pkgs.vips`)
- **S3 bucket** created per environment with appropriate IAM policy
- **Minio or LocalStack** for local development and CI testing
