# Proxy Rules Local Direct Admin Design

Date: 2026-08-04

## Status

Approved in conversation on 2026-08-04.

This specification extends the authenticated Local Proxy management design in
`2026-07-30-proxy-rules-admin-local-sources-design.md`. It replaces the earlier
restriction that Local Direct could not be viewed or edited. Existing compiler,
artifact, refresh, persistence, authentication, and bounded-pagination
contracts remain unchanged.

## Goal

Give authenticated administrators complete, symmetric management of the Local
Proxy and Local Direct domain sources from `/proxy-rules`:

- Add domains to either source with independent forms.
- Apply the same normalization, validation, deduplication, size limits, and
  atomic durability guarantees to both sources.
- Inspect both validated local sources through the existing lazy, virtualized
  source viewer.

The change does not add removal, replacement, file uploads, GFWList editing, or
automatic movement of domains between lists.

## Selected Approach

Generalize the existing local-source mutation boundary and keep two explicit
forms. This was selected over duplicating the Local Direct implementation or
combining both targets into one mode-switching editor.

The shared approach keeps the two lists behaviorally consistent without hiding
the destination of a submission. The UI remains explicit while validation,
atomic writing, reconciliation, bounded errors, and timeouts have one
implementation.

## Domain and Conflict Semantics

Both forms accept UTF-8 textarea input with one domain per line. Empty lines are
ignored. Each submitted domain may use one of these forms:

```text
example.com
.example.com
*.example.com
```

The optional `.` or `*.` prefix is removed. Domains are converted to canonical
lowercase ASCII using the existing IDNA normalizer and stored as bare domains,
such as `example.com`.

URLs, comments, IP addresses, CIDRs, embedded or repeated wildcards, malformed
domains, and invalid UTF-8 remain rejected. A batch is atomic: one invalid line
rejects the complete submission and preserves the original file.

Deduplication applies within the submitted batch and against the selected
source only. A domain may deliberately exist in both Local Proxy and Local
Direct. The compiler continues to preserve and count cross-list conflicts;
gateways resolve them using the documented Direct-before-Proxy evaluation
order. Adding to one form never mutates the other source.

## Core Application Design

The public facade remains the only boundary available to the admin application:

```elixir
GSMLG.ProxyRules.add_local_proxy_domains(text)
GSMLG.ProxyRules.add_local_direct_domains(text)
GSMLG.ProxyRules.get_source_page(source, cursor, options)
```

`get_source_page/3` accepts `:remote_gfwlist`, `:local_proxy`, and
`:local_direct`.

The existing batch helper becomes the source-neutral `LocalDomainBatch`. The
atomic writer becomes `LocalSourceWriter`. These modules remain internal to the
Proxy Rules application and serve both local source kinds.

`GSMLG.ProxyRules.Source.Local` remains the serialization authority. Its shared
mutation call accepts `:proxy` or `:direct`, selects the corresponding validated
snapshot and configured target, prepares the new content, atomically writes it,
and reconciles both source snapshots. The returned reconciliation result is
checked against the selected source.

The existing facade functions preserve bounded error values and timeout
semantics. Invalid non-binary facade input returns the same bounded invalid
batch result for both source kinds. No configured path, process state, or raw OS
error is exposed to Phoenix.

## Admin HTTP and LiveView Design

The authenticated source controller adds Local Direct to the same paginated
JSON contract used by GFWList and Local Proxy. The route is:

```text
/proxy-rules/sources/local-direct
```

The LiveView owns two independent forms and error collections:

- `local_proxy_form` / `local_proxy_errors`
- `local_direct_form` / `local_direct_errors`

Submitting one form never clears or changes the other. Validation and write
failures retain the exact submitted textarea content for the affected form.
Success clears only that form, reports added and duplicate counts, and emits a
source-specific viewer invalidation event.

The page places the Add Local Proxy and Add Local Direct cards side by side on
large screens and stacks them on smaller screens. The Source Viewer remains a
separate full-width card below the forms.

The viewer presents three selectors:

1. GFWList
2. Local Proxy
3. Local Direct

Local Direct uses the existing lazy fetch, opaque version-bound cursor,
line/byte limits, fixed-row virtualization, text-only rendering, copy behavior,
and source-changed recovery. No source body is stored in LiveView assigns or
included in the initial HTML.

## Error and State Behavior

Both forms use the established bounded failure model:

- Invalid batch: retain input and show bounded one-based line errors.
- Permission or atomic-write failure: retain input and show a bounded
  operational message.
- Unknown timeout outcome: retain input and instruct the administrator to
  inspect the selected source before retrying.
- Successful idempotent submission: clear input and report that all domains
  already existed.
- Successful write with failed reconciliation: report the durable write result
  without claiming that compilation or artifact publication succeeded.

Proxy Rules telemetry continues to update readiness, generation, source
metadata, artifacts, conflicts, and diagnostics after either source changes.

## Deployment and Permissions

Both configured local-source targets must support the same-directory temporary
file and atomic rename performed by `LocalSourceWriter`. Production guidance
therefore changes Local Direct from operator-read-only to service-writable,
matching Local Proxy:

- Separate Proxy and Direct directories remain recommended.
- Each directory and target file is owned by the release service identity.
- Each target is writable only by that identity and not by untrusted accounts.
- Container deployments mount both local-source directories read/write.
- Operators continue to use atomic replacement for external edits.

The current `vultr-01` configuration stores both files under the existing
read/write `/data/proxy-rules` bind mount, so the application-level capability
does not require a new host mount.

## Testing Strategy

Implementation follows test-driven development and adds coverage at each
boundary:

- Shared batch tests prove identical canonicalization, prefix handling,
  validation, limits, and deduplication for either target.
- Local source tests prove serialized Direct writes select the Direct snapshot
  and path, preserve Proxy content, reconcile Direct, and map writer failures.
- Facade tests cover Direct success, bounded failures, unavailable processes,
  timeout outcomes, and Local Direct source pagination.
- Controller tests cover authenticated Local Direct pages, cursors, status
  mapping, and unauthenticated rejection.
- LiveView tests cover independent forms, retained errors, Direct success,
  source-specific invalidation, and three-source viewer metadata.
- JavaScript hook tests cover Local Direct selection, URL routing, invalidation,
  lazy loading, and virtualization without increasing the DOM row bound.
- Operational tests assert the updated documentation and writable permission
  contract for both local sources.

Scoped Proxy Rules, admin controller, LiveView, and JavaScript tests must pass.
Formatting and `git diff --check` are required. Unrelated repository failures
remain outside this feature.

## Non-Goals

- Removing individual domains.
- Replacing or reordering complete source files.
- Automatically removing a domain from the opposite list.
- Resolving cross-list conflicts in the compiler or admin UI.
- Editing GFWList, configuration values, or renderer formats.
- Adding a public mutation API.
