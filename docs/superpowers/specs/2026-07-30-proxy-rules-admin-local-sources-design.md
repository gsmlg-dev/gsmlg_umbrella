# Proxy Rules Admin Local Sources Design

Date: 2026-07-30

## Status

Approved in conversation on 2026-07-30.

This specification extends the approved Proxy Rules dashboard and full V1
designs:

- `2026-07-22-proxy-rules-admin-dashboard-design.md`
- `2026-07-23-proxy-rules-full-v1-design.md`

It deliberately replaces two earlier V1 non-goals for the authenticated admin
page: editing the local proxy source and viewing complete source content. The
remaining compiler, lifecycle, persistence, artifact, and failure contracts
stay unchanged.

## Goal

Allow authenticated administrators to:

1. Paste and add one or more local proxy domains from `/proxy-rules`.
2. Inspect the decoded GFWList and the local proxy source without loading
   source bodies during the page's initial render.

The feature preserves the source/renderer separation. Domains added through the
admin are stored as canonical bare domains such as `baidu.com`. Consumers
receive renderer-specific artifacts:

```text
Raw/DNS: baidu.com
Squid:   .baidu.com
Clash:   DOMAIN-SUFFIX,baidu.com
```

## Scope

The admin page gains:

- A textarea that accepts one local proxy domain per line.
- Batch validation, canonicalization, deduplication, and atomic append.
- A source-content card for decoded GFWList and local proxy content.
- Lazy, virtualized source viewing with freshness and stale-state information.

The feature does not add:

- Local direct editing or viewing.
- GFWList editing or uploads.
- URL, wildcard, IP, CIDR, comment, or arbitrary GFWList syntax in the admin
  textarea.
- Runtime configuration editing.
- Public source-content endpoints.
- New renderer formats or gateway configuration mutation.

## Selected Page Layout

Keep the existing authenticated LiveView route and navigation entry:

```text
/proxy-rules
```

Add two bordered DuskMoon cards directly below the existing Sources section:

1. **Add Local proxy**
   - A textarea labeled "One domain per line".
   - A primary "Add domains" submit button.
   - Inline batch validation feedback and a concise result summary.
2. **Source contents**
   - GFWList and Local proxy source selectors.
   - Source status, updated time, line count, and load/reload action.
   - A fixed-height virtualized, copyable text viewer after explicit loading.

The existing summary, source metadata, artifacts, and diagnostics sections
remain in place. GFWList content is collapsed and unfetched by default; its
metadata remains visible.

This inline layout was selected over:

- Header actions with a drawer, which hide recurring paste and inspection
  workflows.
- Separate admin subpages, which add routes and navigation without a current
  need for a larger editor.

## Application Boundaries

`gsmlg_admin_web` must use only the public `GSMLG.ProxyRules` facade. The
LiveView and admin controller must not read or write configured files, call
source GenServers directly, inspect ETS, or access persistence internals.

Extend the facade with operations conceptually equivalent to:

```elixir
GSMLG.ProxyRules.add_local_proxy_domains(text)
GSMLG.ProxyRules.get_source_page(source, cursor, options)
```

Supported admin-view sources are:

```elixir
:remote_gfwlist
:local_proxy
```

The concrete return values must use bounded public result types and reason
atoms. They must not expose configured paths, internal process state, stack
traces, or arbitrary filesystem errors.

`GSMLG.ProxyRules.Source.Local` remains the serialization authority for local
source mutation. It validates and writes through a focused pure/helper module,
then reconciles its authoritative snapshot and notifies the Coordinator.

The Coordinator already owns current validated source snapshots. Source
content reads use those snapshots rather than rereading disk or persistence.
Decoded GFWList content is shown; the original Base64 transport body is not an
admin-view source.

## Batch Input Contract

The textarea accepts UTF-8 text with one domain per line.

Processing is:

1. Normalize line endings.
2. Trim surrounding whitespace.
3. Ignore empty lines.
4. Reject non-domain inputs with their one-based textarea line numbers.
5. Normalize accepted domains to lowercase ASCII using the existing IDNA
   domain normalizer.
6. Deduplicate canonical domains within the submitted batch.
7. Deduplicate canonical domains already present in the current local proxy
   source.
8. Preserve existing source order and append new domains in submission order.

The admin contract is stricter than the general parser. It accepts bare domains
only. It rejects:

- HTTP or HTTPS URLs.
- Other URI schemes.
- Leading comment markers.
- Wildcards or regular expressions.
- IP literals and CIDRs.
- Empty, malformed, overlong, or invalid IDNA names.

Validation is atomic for the entire batch. If any non-empty line is invalid,
the operation returns all bounded line errors and does not modify the file.
An empty submission is a validation error.

Duplicate handling is idempotent. Duplicates are omitted rather than persisted
or reported as failures. A successful result reports:

- Number of new canonical domains added.
- Number of submitted duplicates omitted.
- The accepted canonical domains.

If every valid submitted domain already exists, the operation succeeds with
zero additions and an "already present" result.

## Atomic Local Source Mutation

Mutation is a serialized call to the Local source process.

Before writing, it obtains the current validated local proxy content. The
writer:

- Preserves valid existing source lines and their order.
- Appends only new canonical bare domains.
- Produces normalized LF line endings and exactly one trailing newline for
  non-empty content.
- Enforces the existing 8 MiB local-source limit against the final body.
- Writes a temporary file in the destination directory.
- Flushes and atomically renames the temporary file over the configured target.
- Cleans up its temporary file after a failed operation where possible.

After a successful rename, Local immediately reconciles the file. The existing
notification and Coordinator path performs compilation and artifact
publication. The mutation result means the source file was committed and
reconciliation was requested; it does not claim that a newer artifact was
successfully published.

Concurrent admin submissions are serialized by the Local process so they do
not lose entries. External operators must use atomic replacement when editing
the same file. The documented deployment policy changes the local proxy target
from service-readable to service-readable and service-writable. Local direct
remains read-only.

## Source Content Contract

The source-content viewer reads current validated snapshots:

- GFWList: decoded UTF-8 upstream rules.
- Local proxy: the validated local source text. Admin-added entries are
  canonical bare domains; pre-existing operator comments and accepted legacy
  leading-dot entries remain visible as source text.

A source page includes:

- Source kind.
- Content-version hash.
- Availability (`ready`, `stale`, or `missing`/unavailable as applicable).
- Updated/observed time and last-success time.
- Total line count when known.
- A page of escaped text lines.
- An opaque continuation cursor.
- Whether additional lines remain.

The cursor binds to the content-version hash. If a source changes while the
administrator is browsing, the old cursor returns a bounded
`source_changed` result and the viewer offers reload instead of combining two
versions.

Each page is bounded by both line count and encoded response bytes. The default
UI request is approximately 200 lines; the backend enforces the final maxima.
Pagination and line slicing run outside source and Coordinator GenServer
mailboxes so large inputs do not block lifecycle messages.

No source body is placed in LiveView assigns. An authenticated admin GET route
returns paginated source data for a JavaScript hook. The route lives within the
existing admin authentication boundary and is not exposed through
`gsmlg_web`.

## Virtualized Viewer

The source card initially renders metadata only. Selecting GFWList does not
load content until the administrator clicks "View content".

The admin JavaScript hook:

- Fetches the first authenticated page on demand.
- Requests more pages as the user scrolls.
- Renders only the visible row window plus a small overscan buffer.
- Shows stable line numbers.
- Supports selecting and copying rendered text.
- Resets when the selected source or content-version changes.
- Offers reload after `source_changed`.
- Shows explicit loading, empty, stale, unavailable, and error states.

The Local proxy viewer is invalidated after a successful add operation. It
reloads only if it was already open; otherwise it stays collapsed with updated
metadata.

The UI never interprets source lines as HTML. Server responses are JSON data,
and rows are assigned as text content.

## LiveView Behavior

The add form is a standard LiveView form protected by the existing session and
CSRF boundaries.

On validation failure:

- Keep the textarea content.
- Show invalid line numbers with concise bounded reasons.
- Do not change source content or dashboard readiness.

On write failure:

- Keep the textarea content.
- Show a bounded operational message.
- Do not reveal paths or raw OS errors.

On success:

- Clear the textarea.
- Flash "Added N domains; ignored M duplicates" or the all-duplicates
  equivalent.
- Mark Local proxy viewer metadata as needing refresh.
- Allow existing Proxy Rules telemetry/PubSub events to update generation,
  source state, artifacts, and diagnostics.

The UI distinguishes a successful source write from successful compilation.
If compilation or artifact persistence subsequently fails, the dashboard
truthfully enters `stale` and retains the last-known-good artifact.

## Failure Model

Public facade failures use bounded reasons covering:

- Proxy Rules or Local source unavailable.
- Invalid batch or invalid domain lines.
- Source unavailable or missing.
- Source content changed during pagination.
- Final local body too large.
- Permission denied.
- Atomic write or rename failure.
- Reconciliation failure after a committed write.

Expected failures are data, not LiveView crashes. Internal exception details
are logged through existing bounded telemetry and are not returned to the
browser.

A committed file followed by reconciliation failure is reported distinctly.
The UI explains that domains were saved but publication needs attention and
retains the submitted success count.

## Security and Operations

- Only authenticated admin routes can submit or view source content.
- The public artifact routes remain unchanged.
- Source bodies are never logged.
- Invalid values and diagnostic samples remain bounded.
- Admin responses do not disclose configured file paths.
- The local proxy directory and file must be writable only by the release
  service identity and trusted operators.
- Local direct stays non-writable through this UI.
- Deployment documentation and operational assertions must reflect the new
  write permission requirement for only the local proxy target.

## Testing

### Proxy Rules facade and source process

Test:

- Decoded GFWList and local proxy page reads.
- Lazy page boundaries, opaque cursors, line and byte limits.
- Cursor invalidation when the source version changes.
- Ready, stale, missing, and unavailable source results.
- Valid single and multiline additions.
- URL, comment, wildcard, IP, CIDR, malformed, and empty rejection.
- One-based invalid line reporting.
- Unicode-to-IDNA canonicalization.
- Duplicate removal within a batch and against existing content.
- Existing-order and submission-order preservation.
- LF normalization and exactly one trailing newline.
- Initial missing-file creation.
- Final-body 8 MiB enforcement.
- Permission, temporary-write, flush, and rename failures.
- Concurrent submissions without lost entries.
- Immediate reconcile/Coordinator notification after commit.
- A committed write followed by reconcile failure.

### Admin web

Test:

- Authentication on the page and source-content route.
- Textarea markup, labels, and submit behavior.
- Failed validation retains input and renders bounded line errors.
- Success clears input and reports added/duplicate counts.
- GFWList metadata renders without a content request on initial load.
- Explicit load, paging, source switching, and version-change reload.
- Local viewer invalidation after an add.
- Stale last-known-good presentation.
- Missing and unavailable presentation.
- Source text is escaped and never rendered as HTML.
- JavaScript virtual list loading, scrolling, reset, and error states.

### Scoped verification

Run tests scoped to:

- `apps/proxy_rules`
- The Proxy Rules LiveView, admin source controller, routing, and frontend hook
  in `apps/gsmlg_admin_web`

Also run scoped formatting, warnings-as-errors compilation, strict Credo where
applicable, JavaScript checks, and a browser verification of `/proxy-rules`.
Do not fix unrelated failures.

## Definition of Done

The feature is complete when:

1. An authenticated administrator can paste bare domains, one per line, and
   atomically add all valid non-duplicate domains.
2. Invalid batches do not modify the local proxy file and identify invalid
   lines.
3. Admin-added entries are stored as bare domains while Raw/DNS, Squid, and
   Clash artifacts retain their format-specific output.
4. Concurrent submissions cannot lose domains and final content respects the
   8 MiB bound.
5. GFWList content is not loaded by default.
6. Administrators can explicitly inspect decoded GFWList and local proxy
   content through bounded pages in a virtualized viewer.
7. Source-version changes cannot mix content from different snapshots.
8. Write, reconcile, compile, and publication outcomes are represented
   truthfully and do not discard the last-known-good artifact.
9. No source content, filesystem path, or raw internal error leaks through
   logs or browser responses.
10. Scoped backend, admin, JavaScript, formatting, compilation, and browser
    checks pass.
