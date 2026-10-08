# GaoNote Agent Note API implementation status

Date: 2026-10-08. This report describes the uncommitted implementation in
`/home/gao/Workspace/gsmlg-dev/gsmlg_umbrella/.trees/gaonote-api-parity`, branch
`codex/gaonote-api-parity`, baseline `9d7e129c7b65fd5f3f51057e6feab9b3df6c5810`.
The fixed reference is `gsmlg-opt/agent-note@1a16690d3f0bcdb08e00752e46d76f234313416b`.

The worktree now contains the Note REST adapters and twelve canonical MCP tools.
This is **an implementation with scoped contract tests, not complete API parity or
production qualification**. Modern MCP transport, real search/index services,
real Gotenberg output, full image decoding, and rendering equivalence remain
unqualified. No commit, push, merge, release, or deployment is included.

The [original review](2026-10-08-gaonote-agent-note-api-parity.md), its baseline
logs and frozen inventories remain unchanged as historical evidence. The
[implementation plan](../superpowers/plans/2026-10-08-gaonote-agent-note-api-parity.md)
tracks remaining acceptance gates. System REST and Org REST/MCP remain outside
this implementation scope.

## Source inventory

A read-only source comparison matched the dedicated OpenAPI operation arrays
against the frozen Note inventory: 24 operations, with no additional note PATCH.
The inventory's `openapi_path` normalizes the attachment wildcard from `{*path}`
to `{path}`. Canonical server component names also match all twelve frozen tools.
These checks establish source inventory, not runtime discovery or every wire
schema and response.

| Method | Canonical path | Adapter |
|---|---|---|
| GET | `/api/notes` | List summaries |
| POST | `/api/notes` | Save note |
| GET | `/api/notes/count` | Count notes |
| GET | `/api/notes/{id}` | Note detail |
| PUT | `/api/notes/{id}` | Revision-guarded replacement |
| DELETE | `/api/notes/{id}` | Revision-guarded soft delete |
| POST | `/api/notes/search` | Shared external search adapter |
| POST | `/api/notes/bulk-labels` | Selector bulk labels |
| POST | `/api/notes/batch-labels` | Selected revision-guarded label actions |
| POST | `/api/notes/batch-delete` | Selected revision-guarded deletion |
| GET | `/api/notes/{id}/raw` | Markdown or embedded HTML |
| GET | `/notes/{id}/content` | Content alias |
| GET | `/api/notes/{id}/attachments/{path}` | Existing attachment-byte controller |
| GET | `/api/notes/{id}/export/pdf` | Saved-revision PDF adapter |
| GET | `/api/trash` | Deleted summaries |
| POST | `/api/trash/restore` | Atomic restore |
| DELETE | `/api/trash/{id}` | Revision-guarded permanent deletion |
| GET | `/api/labels` | Label catalog |
| POST | `/api/labels` | Define label key |
| PUT | `/api/labels/{key}` | Update label key |
| DELETE | `/api/labels/{key}` | Delete label key |
| GET | `/api/dashboard` | Counts/categories and conditional ETag |
| POST | `/api/render` | Render Markdown fragment |
| GET | `/api/export/capabilities` | Configured-format discovery |

Canonical `/mcp` registers only tools:

`save_note`, `get_note`, `list_notes`, `semantic_search`, `read_note_lines`,
`replace_note`, `patch_note`, `delete_note`, `bulk_update_note_labels`,
`put_note_attachment`, `get_note_attachment_content`, `delete_note_attachment`.

It is mounted on the public web endpoint with
`transport: {:streamable_http, start: true}`. Existing `/api/gao_notes`,
`/mcp/gao_note` and LiveView entry points remain separate compatibility surfaces.

## Implemented shared behavior

- `Compat`, `Compat.Catalog` and `Compat.Bulk` provide dedicated domain adapters;
  `Compat.Presenter` separates REST tuple labels from MCP label objects and
  serializes timestamps as Unix seconds.
- Active summaries sort by creation time descending/id ascending; trash sorts
  by deletion time descending/id ascending, matching the reference.
- Notes have shared positive revisions. Guarded mutations lock the relevant
  note and compare the expected revision before changing state. Legacy field,
  label, lifecycle, attachment and batch writers participate in revision updates;
  no-op behavior and concurrent-writer regressions have scoped tests.
- `ContentPatch` applies strict anchored `@@` hunks without fuzzy matching.
  `NoteLines` retains CR/trailing empty lines and computes the raw-byte FNV-1a32
  tag. Patch omission, explicit null and empty arrays have distinct meanings.
- Selectors support presence, AND terms, typed comparisons and percent-decoded
  exact equality. Catalog keys are case-sensitive. Legacy case-insensitive
  lookup rejects ambiguous matches rather than merging existing labels.
- Attachments retain their internal global storage identity and add note-scoped
  API identity. Aggregate MCP attachment mutations enforce content XOR;
  standalone put allows identical text/base64 representations.
- REST controller errors remain operation-specific: plain text for read/create
  failures and structured mutation errors. Canonical malformed JSON handling is
  isolated in `AgentNoteParsers`; ordinary legacy parsing is preserved.
- Dedicated OpenAPI operations are merged with legacy documentation. MCP input
  and output schemas live in `AgentNoteTools`, separately from REST schemas.

Regex uses bounded OTP PCRE and rejects obvious Rust-unsupported lookaround and
backreferences. This is an explicitly documented approximation: Rust regex
Unicode/class-set syntax and complexity behavior are not fully reproduced.

Catalog concurrency retains a lock-order tradeoff. A note-first mutation racing
a catalog writer can deadlock; the database rolls back the losing transaction
completely. Catalog writers return a tagged failure, but compat note/attachment
transactions can still propagate a `Postgrex` exception through Phoenix as a
500 response, requiring the client to retry. Scoped race tests establish database
safety and rollback, not alignment of every REST/MCP error body under contention.

## Database changes and preservation

| Migration | Effect |
|---|---|
| `20261008000000_add_gao_note_revision` | Bigint revision, default 1, not null, positive constraint |
| `20261008000001_add_gao_note_compat_identity` | Backfill attachment `api_id = id`; unique `(note_id, api_id)`; exact label-name uniqueness |
| `20261008000002_remove_gao_note_historical_lower_index` | Remove the case-insensitive index retained under the historical tag-table name |
| `20261008000003_allow_string_gao_note_audit_entity_ids` | Convert audit entity identity from UUID to text without rewriting existing values |

Production migration and representative production-data acceptance have not
been performed. Rollback needs a data decision: case variants introduced after
the forward migration can prevent recreating a lower-name unique index, and
non-UUID audit identities can prevent the text-to-UUID down migration. Do not
treat reversible migration declarations as proof that arbitrary new data can
be rolled back safely.

## Configuration and external services

The TOML schema/setup/defaults add `[gao_note]` with `index_url`, `search_url`,
`search_token`, `minimum_score` (default `0.01`) and `pdf_renderer_url`. Setup
stores these settings under `:gsmlg_gao_note, :compat_services`. Empty URLs
disable external capabilities. Existing locked Finch and MDEx packages are now
declared directly by their consuming apps; this work does not upgrade the
Backplane lock entry, which remains `1.6.3`.

`search_url` and `index_url` are the actual POST endpoints, including any path;
the adapter does not append a service route. Both use the same `search_token`
as an optional Bearer token. `pdf_renderer_url` is the Gotenberg base URL, to
which the PDF adapter appends `/forms/chromium/convert/html`.

Search is shared by REST/MCP, preserves service-provided scores and applies the
minimum score, current-note existence/deletion and label checks. Blank queries
and zero limits return empty results after selector validation. HTTP responses
are streamed with byte limits. Real title/dense retrieval and weighted RRF
(`title=3`, `content=1`, `k=60`) remain an external-service acceptance gate.
The service receives the requested limit; local post-filtering can underfill
results. Reference overfetch/limit filling has not been demonstrated.

For example, the external search exchange is:

```json
{"query":"release notes","limit":10,"label":"topic=release"}
```

```json
[{"id":"8b4f8770-fad4-4ae8-86cb-31a9554a5fd8","score":0.02}]
```

This is the service response shape, not the canonical REST response. The
adapter hydrates current GaoNote summaries, filters them and adds the received
score. The example score describes JSON syntax only; it is not ranking evidence.

`IndexWorker` uses the `gao_note_index` Oban queue, retries and uniqueness;
delivery uses the `note_chunking.md` envelope, idempotency key and acknowledgement
validation. Create/update/restore note audit events enqueue the latest saved
snapshot. Delete/tombstone delivery is not implemented here; deleted/missing
notes are skipped by the worker and excluded during result hydration. External
stale-index cleanup, index progress and actual retry/idempotency behavior remain
unqualified. Dashboard `embedded_note_count = 0` and `embedding_note = nil`
represent the lack of external indexing status integration.

Index success requires HTTP 200/202 and a JSON acknowledgement containing the
matching request UUID, note ID and ISO updated timestamp, plus status `accepted`
or `completed`. A minimal acknowledgement looks like:

```json
{"request_id":"b2f2b221-34c4-4f7f-87c0-9907b9142b8d","note_id":"8b4f8770-fad4-4ae8-86cb-31a9554a5fd8","updated_at":"2026-10-08T00:00:00.000000Z","status":"accepted"}
```

Missing or mismatched acknowledgement fields are failures, not successful
delivery. An `accepted` acknowledgement alone does not prove indexing completed.

PDF capability reports renderer configuration, not renderer health. The adapter
freezes a locked saved revision, checks referenced asset size/checksum, rejects
remote image references, packages local files and streams a bounded PDF response.
Current fixed limits include two concurrent exports, a 35-second overall task
deadline, 2 MiB Markdown, 64 referenced images, 8 MiB per asset, 32 MiB PDF
output/package and 20/80 million per-image/combined pixels. These are implementation
limits, not a reproduction of all reference configurable export limits.

Export workers now use `Task.Supervisor.async_nolink` with the existing
`GSMLG.TaskSupervisor`; unexpected worker exceptions return a retryable 503
without terminating the request caller, and release the monitored capacity lease.
A malformed renderer URL regression failed before this repair and passes in
the final integrated run.

`AgentNoteImageInfo` validates bounded PNG/GIF/JPEG/WebP headers and dimensions.
It does not decode compressed pixels or validate later frames/chunks. SVG/data
image handling, full decoder validation, reference export styling/footnotes,
filename behavior and detailed limit/path error responses remain different or
unqualified. Stub `%PDF-` responses establish adapter behavior only; a real
Gotenberg render and readable PDF still need evidence.

## Security exceptions and remaining qualification

- REST writes, attachment bytes and PDF require public Guardian access-token
  authentication. Ordinary note reads, search/render and capability discovery
  retain the existing optional-auth policy. This differs from the reference
  unauthenticated server surface.
- `/mcp` accepts a public Guardian access token or one existing GaoNote service
  key through `x-api-key`/`x-gaonote-mcp-key`; missing, refresh, malformed and
  ambiguous credentials are rejected. It does not introduce a core-to-web
  dependency.
- Existing attachment ownership, streaming, Range and `nosniff` behavior are
  retained. Range is a project extension, not a reference parity claim.
- HTML uses sanitized MDEx output, CSP and escaped attachment bases. Embedded
  documents include styles and tasklists, but reference raw HTML anchors,
  Mermaid, syntax highlighting and exact styling are not reproduced/qualified.
- Origin enforcement remains a deployment/transport qualification requirement.
  The canonical wrapper adds authentication, not an Origin policy; the locked
  StreamableHTTP plug does not provide demonstrated Origin enforcement. No
  browser-origin safety claim follows from successful authenticated tool calls.
- Modern MCP 2026 wire qualification remains **BLOCKED_UPSTREAM** by
  [gsmlg-opt/backplane#56](https://github.com/gsmlg-opt/backplane/issues/56).
  No app protocol shim or fork was introduced. Actual release/dependency update
  and discover/no-session/header/result metadata checks remain required.
- Invalid-input acceptance also remains **BLOCKED_UPSTREAM** by
  [gsmlg-opt/backplane#58](https://github.com/gsmlg-opt/backplane/issues/58)
  (Bug, `internal request`, blocker). The installed Backplane/Peri validator can
  crash on unknown top-level or nested fields instead of returning the expected
  protocol error. Canonical and legacy callsites carry `TODO(upstream)` tracking.
  The failing acceptance cases remain enabled; no local validator shim is used.
  Resolution requires an upstream fix and dependency update, then rerunning the
  affected malformed-input tests. Exact final failures belong in the parent
  verification block below.

## Verification handoff

The final read-only documentation pass ran no Mix or production/test edits.
Source inventory comparison matched REST 24 and MCP 12 against the frozen
fixtures. Scoped suites cover domain revisions/concurrency, catalog/batches,
strict patch/lines/selectors, REST/MCP schemas/auth/execution, image headers,
service adapters and existing GaoNote regressions.

The additional catalog missing-row race regressions were reproduced before
repair: `/tmp/gaonote-catalog-missing-red.log` records **12 tests, 3 failures**.
This is the intentional red evidence, not a final integrated failure count;
the final repaired results are recorded below.

Final scoped run: **343 tests, 340 passed, 3 failed**, command exit 2.

| App / scope | Tests | Failures |
|---|---:|---:|
| `gsmlg_gao_note` complete app tests |248|0|
| `gsmlg_web` named GaoNote/canonical controller suites |66|0|
| `gsmlg_config` GaoNote service configuration |1|0|
| `gsmlg_admin_web` GaoNote MCP/attachment suites |28|3|

All three enabled failures reproduce Backplane #58: legacy `update_note`
rejecting additional attachments, unknown top-level fields, and unknown nested
attachment fields. Expected JSON-RPC `-32602` becomes `-32603` after dependency
validation crashes. These cases were not skipped or made to accept the crash.
No all-suite green or complete wire compatibility claim is made.

The new missing-catalog-row races, deletion-time/id trash ordering, exact
catalog-description whitespace, and detached PDF-worker error/capacity cases
all pass in this integrated run. Before repair, the last two regressions failed
as expected: trash 7 tests / 1 failure and PDF services 5 tests / 1 failure.

Reproduce from the stated worktree using the exact
[scoped command](fixtures/gaonote-agent-note-20261008/implementation-scoped-command.sh).
Full output is preserved in
[final scoped log](fixtures/gaonote-agent-note-20261008/implementation-final-scoped.log).
The test environment uses the separate `gsmlg_test_api_parity` database owned
by `gao`, cloned schema only; production/dev data and original DB permissions
were not modified. The four forward migrations ran only against this test DB.

Changed-file formatting and `git diff --check` pass. Existing umbrella startup
warnings remain: missing Bun React Markdown/highlighting packages, distribution
startup, existing compiler/test-helper warnings. Intentional fixture storage
failures and the renderer-crash regression also log errors. No umbrella-wide
warnings-as-errors, assets build, dialyzer, or production readiness claim is made.

The original baseline failures and fixture repairs are historical evidence,
not current acceptance results. Completed fixture repairs include mixed-map
syntax/import ambiguity, ExUnit-supervised Bandit ownership and the admin
session secret-key helper. The three final failures remain enabled and are
identified above.

The admin standalone attachment-page regression now checks the actual HTML
404 response from the router catch-all rather than expecting a raised error;
the 404 contract remains required. The error template tolerates absent `:flash`
when invoked outside the browser pipeline. These repairs do not authorize a
successful standalone attachment page or remove its negative assertion.

Before calling the full objective complete, qualify modern MCP wire behavior
and upstream invalid-input handling,
real external ranking/index delivery/status, real Gotenberg output, remaining
renderer/decoder differences, deployment Origin/auth configuration and migration
data behavior, then compare the same normalized request fixtures against both
fixed reference and GaoNote. Passing scoped tests does not close those gates.
