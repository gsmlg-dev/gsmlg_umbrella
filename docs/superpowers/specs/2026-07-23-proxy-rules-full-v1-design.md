# Proxy Rules Full V1 Design

Date: 2026-07-23

## Status

Approved in conversation on 2026-07-23.

This specification continues agent note
`93ffe9ab-78e9-4203-a572-91a69af4f8a7`, "Proxy Rules Integration Plan",
and the approved admin addendum
`2026-07-22-proxy-rules-admin-dashboard-design.md`. The note remains
authoritative where this document does not make a previously recommended detail
explicit. Milestone 1 is already implemented. This specification covers the
remaining V1 work from Milestones 2 through 8 and completes the operational
dashboard.

## Goal and Scope

Deliver the complete domain-only proxy-rules service inside `gsmlg_umbrella`:

- Fetch and validate the official Base64-encoded GFWList.
- Ingest optional local proxy and direct domain files.
- Compile proxy and direct lists independently.
- Normalize, deduplicate, hierarchically fold, and diagnose rules.
- Pre-render raw, Squid, and Clash artifacts for both lists.
- Publish complete immutable generations atomically through ETS.
- Persist and restore last-known-good source and artifact snapshots.
- Expose the six fixed public download endpoints with conditional caching.
- Expose truthful ready, refreshing, stale, and failure states in
  `gsmlg_admin_web`, including safe manual refresh.
- Emit bounded operational telemetry and provide deterministic tests,
  benchmarks, and deployment documentation.

V1 does not add rule editing, runtime configuration editing, uploads, multiple
remote sources, a complete Adblock engine, path or regular-expression routing,
IP/CIDR rules, GeoIP/GeoSite integration, a separate endpoint, a separate
release, or gateway configuration mutation.

## Selected Approach

Use a versioned snapshot pipeline. Pure modules parse and compile immutable
source values. Runtime processes own only scheduling, mutable source state,
serialized generation authority, and ETS publication. Expensive compilation
runs in supervised unlinked tasks.

This was selected over:

- A periodic full rebuild in one coordinator, which would rebuild unchanged
  inputs and weaken filesystem responsiveness and failure isolation.
- A database or Oban workflow, which would add persistence and database
  coupling that the independent OTP application does not need.

All remaining V1 work will be delivered on one branch in milestone-sized,
reviewed commits.

## Application Boundaries

`apps/proxy_rules` remains Phoenix-independent and exposes only the stable
facade:

```elixir
GSMLG.ProxyRules.get_artifact(list, format)
GSMLG.ProxyRules.metadata()
GSMLG.ProxyRules.refresh()
```

Supported lists are `:proxy` and `:direct`. Supported formats are `:raw`,
`:squid`, and `:clash`.

The application may depend on focused infrastructure libraries required by its
responsibilities: Finch for bounded HTTP streaming, FileSystem for directory
watching, `:idna` for IDNA conversion, `:telemetry` for events, and the shared
GSMLG telemetry utility for structured sampled logs. It must not depend on
Phoenix, either web application, Ecto, or Oban.

`gsmlg_web` depends on `proxy_rules` and owns the public HTTP controller.
`gsmlg_admin_web` depends on `proxy_rules` and uses an admin-local telemetry
bridge to publish status changes through the existing `GSMLG.PubSub`.

## Supervision and Runtime Processes

The completed supervision tree uses `:one_for_one`:

```text
GSMLG.ProxyRules.Supervisor
|-- GSMLG.ProxyRules.TaskSupervisor
|-- GSMLG.ProxyRules.Finch
|-- GSMLG.ProxyRules.Store
|-- GSMLG.ProxyRules.Source.Remote
|-- GSMLG.ProxyRules.Source.Local
`-- GSMLG.ProxyRules.Coordinator
```

Each process has a runtime reason:

- Finch owns reusable HTTP connection pools.
- Store owns the protected ETS table and serializes writes.
- Remote owns fetch scheduling, validators, and retry state.
- Local owns filesystem subscription, debounce, and reconciliation timers.
- Coordinator owns authoritative generation ordering and active compilation
  state.
- TaskSupervisor contains compilation failures and keeps the Coordinator
  responsive.

Stateless parsing, normalization, compilation, rendering, hashing, and
persistence encoding remain plain modules.

Store starts before source services and the Coordinator. It attempts to restore
a persisted artifact during initialization. Source services perform restored
source loading and initial ingestion in `handle_continue/2`, keeping startup
callbacks short.

## Domain and Rule Model

An accepted V1 rule is a suffix-domain decision with these conceptual fields:

```text
domain
reversed_labels
match
action
source
location
```

`match` is `:suffix`; `action` is `:proxy` or `:direct`; `source` identifies
remote GFWList, local proxy, or local direct input. `location` is retained only
for bounded diagnostics and is not rendered into artifacts.

All accepted domains pass through one normalizer:

1. Trim surrounding whitespace.
2. Remove an optional leading suffix dot and trailing DNS root dot.
3. Convert a supported URL rule to its hostname before normalization.
4. Convert Unicode domains to IDNA ASCII/Punycode.
5. Lowercase the resulting ASCII value.
6. Reject empty labels, IP literals, malformed wildcard placement, invalid
   hostname characters, labels longer than 63 octets, and names longer than
   253 octets.
7. Precompute reversed labels once for folding.

Normalization is idempotent. The compiler does not repeatedly split and join
the normalized domain string.

## Parsers

### Local files

The two configured local files contain one domain per line. Blank lines and
lines beginning with `#` or `!` are ignored. Leading and trailing suffix dots
are accepted. Full GFWList syntax is not accepted in local files.

Each invalid local line is skipped, counted, and eligible for the bounded
diagnostic sample. A missing file is an empty valid source on first startup and
remains watched for creation. After a file has produced a valid snapshot, a
temporary disappearance retains the previous snapshot so atomic replacement
does not transiently erase local rules.

### GFWList

The remote service removes Base64 whitespace, decodes the complete response,
and validates UTF-8 before a response becomes an authoritative remote source
snapshot.

The pure GFWList parser classifies metadata, comments, proxy rules, direct
exceptions, unsupported rules, and invalid rules before domain extraction.
It safely supports:

- Domain anchors such as `||example.com^`.
- Direct exceptions such as `@@||example.com^`.
- Plain unambiguous host or domain rules.
- HTTP or HTTPS rules whose semantics apply to the complete hostname and do
  not contain a path, query, fragment, modifier, wildcard, or regular
  expression.

Path-specific rules, regular expressions, modifiers, ambiguous wildcards, and
other rules that could be broadened by conversion are skipped as unsupported.
Malformed candidates are skipped as invalid. Neither category causes an empty
artifact or replaces a valid source snapshot.

## Source Snapshots

Remote source snapshots contain the validated decoded text plus:

```text
source_url
etag
last_modified
fetched_at
content_sha256
```

The persisted remote cache contains the original upstream body and metadata in
a versioned checksum envelope. Restore revalidates the envelope, Base64, UTF-8,
and content hash before use.

Local source snapshots are independent for proxy and direct files and contain
normalized source text, content hash, path, observed timestamp, and availability
state. Source-text normalization standardizes line endings and trailing
whitespace before hashing. Comment-only changes may trigger compilation, but
identical normalized content does not.

Only a meaningful content-hash change advances source generation. Changed HTTP
metadata with identical remote content updates source status but does not
recompile artifacts.

## Compiler Pipeline

The compiler is pure and accepts one valid remote snapshot plus the latest
valid local proxy and direct snapshots. A valid remote snapshot is required for
the first artifact; V1 will not silently publish a local-only ruleset that looks
complete.

The pipeline is:

```text
parse
-> classify
-> normalize
-> partition by action
-> merge local rules
-> remove exact duplicates
-> diagnose cross-list conflicts
-> fold each list independently
-> sort deterministically
-> render six bodies
-> hash bodies and build metadata
```

Proxy and direct lists never delete from each other. If `example.com` appears
in both, both remain and one conflict is recorded. Downstream systems must
evaluate direct before proxy.

Within one list, a parent suffix removes descendants. For example,
`example.com` covers `www.example.com`. Folding uses reversed labels and has
linear work in the total label count after deterministic sorting.

Individual invalid or unsupported lines are diagnostic results, not systemic
compilation failures. Invalid source snapshot shapes, invariant violations, or
unexpected parser failures fail the complete generation.

## Rendered Artifact

A successful generation contains:

```text
generation
compiled_at
readiness
source_versions
rendered_outputs
statistics
diagnostics
last_error
```

`rendered_outputs` contains all six list-format combinations. Each output has:

```text
body
sha256
etag
last_modified
content_type
content_length
```

Rules are lexicographically sorted by normalized domain. Non-empty bodies end
with one newline; empty bodies are empty binaries.

- Raw renders `example.com`.
- Squid renders `.example.com`.
- Clash renders `DOMAIN-SUFFIX,example.com`.

All output content types are `text/plain; charset=utf-8`. SHA-256 is lowercase
hex. The HTTP ETag is the quoted value `"sha256-<hex>"` derived from the exact
body. `last_modified` is the generation compilation time truncated to whole
seconds.

Statistics retain complete counts. Diagnostic samples are capped by
`unsupported_rule_sample_limit`; the implementation never retains or logs the
complete upstream list as diagnostics.

## Publication and Operational State

The named protected ETS table continues to use one logical record:

```text
{:current, snapshot}
```

Reads bypass the Store GenServer. Writes pass through Store so only the table
owner mutates the record. Publication replaces the complete record atomically.
When only readiness or an operational error changes, the replacement snapshot
reuses existing rendered binaries and keeps the artifact generation unchanged.

Readiness semantics are:

- `not_ready`: no artifact has ever been published or restored.
- `refreshing`: a fetch or compilation for newer state is active while zero or
  one older artifact may still be served.
- `ready`: current configured sources have been reconciled successfully.
- `stale`: a restored or previously compiled artifact is served after startup,
  source failure, compile failure, or persistence failure.

A restored artifact is published immediately as `stale`. It becomes `ready`
only after current remote and local sources reconcile successfully.
After all three source snapshots are known, the Coordinator compares their
content hashes with the restored artifact's `source_versions`. Matching hashes
promote the restored artifact to `ready` without a redundant compilation;
different hashes schedule a new generation.

`metadata/0` returns readiness and operational status even when no artifact is
ready. Before first publication, artifact-specific fields remain absent rather
than becoming fabricated zero values. `get_artifact/2` returns
`{:error, :not_ready}` until an artifact exists.

## Coordinator and Generations

The Coordinator receives versioned source snapshots and manual refresh
requests. Every meaningful source-content change advances a monotonically
increasing generation.

Only one compilation task is active. It is started with
`Task.Supervisor.async_nolink/2`. If newer source content arrives, the active
task is allowed to finish but becomes non-authoritative. Its result is
discarded, and only the latest pending generation runs next. Rapid updates
therefore coalesce into one authoritative follow-up generation.

The Coordinator remains responsive while parsing, sorting, rendering, hashing,
and persistence work runs outside its mailbox. Task crashes and timeouts become
failed-generation status without crashing the Coordinator.

Manual refresh returns `{:ok, :accepted}` once the request is accepted. An
already active remote fetch is not duplicated; the request is coalesced.
Acceptance never means successful publication.

## Remote Source Service

Remote uses its own named Finch pool and a small injectable transport behavior.
Production transport streams response chunks and stops once
`remote_max_body_size` would be exceeded. Tests substitute deterministic
transports and also exercise a local HTTP server for end-to-end Finch behavior.

Requests use configured connection and receive timeouts. Cached upstream ETag
and Last-Modified values become `If-None-Match` and `If-Modified-Since` headers.

- A valid `200` response is decoded, validated, hashed, and atomically persisted
  before notifying the Coordinator.
- A `304` response refreshes source freshness without compiling.
- A `200` response with unchanged content updates freshness and validators
  without compiling.
- Other statuses, timeouts, response-limit violations, invalid Base64, invalid
  UTF-8, and persistence failures retain the previous remote source and current
  artifact.

Success resets retry state and schedules `remote_refresh_interval`. Failure
schedules configurable exponential backoff bounded by `retry_min_interval` and
`retry_max_interval`; jitter is applied only when enabled. Manual refresh uses
the same validation and state transition path as scheduled refresh.

## Local Source Service

Local watches the unique containing directories of both configured files, not
only the current inodes. This detects in-place edits, atomic rename, symlink
replacement, and Nix-style directory-entry changes.

Relevant filesystem events start or reset one debounce timer. When it fires,
both configured paths are reconciled. A periodic reconciliation timer rereads
both files even if no event arrives. Only changed normalized content notifies
the Coordinator.

File read or parse failures retain the previous valid snapshot and mark the
source stale. The watcher process is linked to Local; a watcher failure restarts
only Local under the top-level `:one_for_one` supervisor.

## Persistence and Recovery

Persistence uses the configured state directory and the fixed layout:

```text
remote.body
remote.metadata
artifact.snapshot
```

Metadata and artifact files use versioned envelopes containing payload type,
schema version, payload checksum, and payload. Decoding uses safe term options
and validates the expected structure and checksum before returning data.

Writes create a uniquely named temporary file in the destination directory,
write the complete bytes, call `:file.sync/1`, close the file, and atomically
rename it over the destination. Temporary files are cleaned after expected
failures.

A newly compiled artifact is persisted before ETS publication. If persistence
fails, the prior artifact remains current and the service becomes stale. This
ensures every published generation satisfies the host-restart recovery
contract.

Missing snapshots are normal on first startup. Corrupt, incompatible, or
partially written snapshots are ignored, diagnosed, and never crash the
supervision tree.

## Public HTTP API

The existing public Phoenix application adds unauthenticated read-only routes:

```text
GET /api/proxy-rules/proxy-list/raw
GET /api/proxy-rules/proxy-list/squid
GET /api/proxy-rules/proxy-list/clash
GET /api/proxy-rules/direct-list/raw
GET /api/proxy-rules/direct-list/squid
GET /api/proxy-rules/direct-list/clash
```

One controller validates path identifiers and maps them to facade atoms. It
does not access ETS, parse, compile, sort, render, or hash.

Successful responses include:

```text
ETag
Last-Modified
Cache-Control
Content-Length
Content-Type
X-Proxy-Rules-Generation
```

`Cache-Control` comes from validated runtime configuration. GET uses weak ETag
comparison semantics and accepts comma-separated `If-None-Match` values and
`*`. A match returns `304` with cache validators and no body. Invalid list or
format identifiers return `404`; a valid route with no artifact returns `503`.

API hits and conditional hits emit telemetry. Request processing only performs
validation, one facade lookup, header work, and response transmission.

## Admin Dashboard Completion

An admin-local bridge process attaches to proxy-rules telemetry and broadcasts
status changes on one `GSMLG.PubSub` topic. This preserves the rule
application's Phoenix-independent boundary. The bridge detaches its telemetry
handler on shutdown and uses a stable unique handler id.

Connected Proxy Rules LiveViews subscribe to that topic and reload metadata
through the facade. They never fetch upstream content, watch files, access ETS,
or poll an external service.

The existing page is completed to show:

- Truthful `not_ready`, `refreshing`, `ready`, and `stale` badges.
- Generation, compilation time, rule counts, source freshness, validators, and
  last successful timestamps.
- All six artifact rows with size, shortened ETag display, last-modified time,
  and working download links.
- Full aggregate diagnostic counts and only bounded diagnostic samples.
- The latest concise operational failure without exposing bodies or sensitive
  paths beyond the configured source labels.

Download URLs are absolute URLs built from `GSMLG.Web.Endpoint.url/0`, because
the admin application runs on a different endpoint and port. The admin app adds
an explicit umbrella dependency on `gsmlg_web` for this URL contract.

Clicking refresh calls `GSMLG.ProxyRules.refresh/0` once. Accepted requests set
the local presentation to refreshing and disable duplicate clicks. Only a
subsequent status event can show success. Expected rejection or failure keeps
existing artifact links and presents a concise flash.

## Telemetry and Logging

Events use the prefix `[:gsmlg, :proxy_rules]` and cover:

- Remote fetch start, stop, exception, and not-modified.
- Local source change and reconciliation failure.
- Compilation start, stop, exception, and stale-result discard.
- Artifact publication and restoration.
- Readiness/status change.
- API artifact hit and conditional hit.
- Unsupported and invalid rule samples.

Measurements include duration, response and artifact sizes, input and output
rule counts, duplicate and collapsed counts, conflict counts, invalid and
unsupported counts, and generation. Metadata contains bounded identifiers such
as source, list, format, HTTP status, and normalized failure category.

Structured logs use the shared telemetry logging utility. Unsupported and
invalid rule logs are capped per compilation by
`unsupported_rule_sample_limit`; complete source bodies and unbounded rule
collections are never logged.

## Configuration and Deployment

The Milestone 1 configuration keys and defaults remain authoritative:

```text
source_url
remote_refresh_interval
remote_connect_timeout
remote_receive_timeout
remote_max_body_size
retry_min_interval
retry_max_interval
retry_jitter
local_proxy_list_path
local_direct_list_path
local_watch_debounce
local_reconciliation_interval
state_directory
cache_control
unsupported_rule_sample_limit
```

No new V1 configuration keys are required. Runtime components receive one
validated configuration value during supervision startup rather than reading
and mutating application environment throughout their work.

The existing umbrella release remains the only deployment unit. Relevant Nix
or service packaging creates or declares the configuration and state
directories. The service user receives read access to configuration and
read/write access to state. Operational documentation describes permissions,
manual refresh, stale diagnosis, cache behavior, and direct-before-proxy
downstream ordering.

## Test Strategy

### Unit tests

Asynchronous pure tests cover:

- Base64 and UTF-8 validation.
- GFWList line classification and safe hostname extraction.
- Unsupported and invalid rule handling.
- Local parsing.
- ASCII and IDNA normalization and rejection constraints.
- Exact deduplication and independent hierarchical folding.
- Cross-list conflict preservation.
- Deterministic rendering, hashing, and ETags.
- Persistence envelope validation.

A vendored, attributed official GFWList fixture verifies real upstream payload
decoding. Smaller synthetic fixtures isolate supported, unsupported, and
malformed cases.

### Property tests

StreamData verifies:

- Normalization idempotence.
- Compilation determinism.
- Duplicate invariance.
- Parent folding only within one list.
- Direct descendants never delete proxy parents.
- Rendering and body hashes remain stable for equivalent normalized input.

### Integration and concurrency tests

Tests cover:

- Streamed HTTP `200`, `304`, timeout, oversized response, invalid Base64, and
  identical-content metadata changes.
- Local file creation, edit, atomic replacement, symlink change, debounce, and
  periodic reconciliation under unique temporary directories.
- Remote and artifact persistence, corrupt snapshots, and offline restoration.
- Refresh coalescing, generation supersession, stale result rejection,
  compilation failure, and persistence-before-publication.
- Continuous concurrent ETS reads during publication, asserting every reader
  sees one complete generation.
- All six public responses, headers, `304`, `404`, and `503`.
- All dashboard states, absolute public download links, refresh behavior,
  PubSub updates, and bounded diagnostics.

Tests avoid global application-environment mutation where options can be passed
directly. Runtime-process tests use unique names and tables when practical;
tests that exercise fixed production names remain explicitly synchronous.

### Benchmark and operational verification

A reproducible benchmark script records compile time, total artifact size, and
direct ETS lookup throughput using the vendored official fixture. It documents
the hardware and fixture hash with results rather than enforcing brittle timing
thresholds in CI.

Scoped application, config, public web, and admin web tests run throughout.
Final verification includes scoped format checks, warnings-as-errors
compilation, and release assembly. Pre-existing unrelated failures are reported
and not repaired under this feature scope.

## Delivery Sequence

Implementation proceeds in these independently reviewable slices:

1. Domain model, local parser, hierarchy, renderers, artifact builder, and
   properties.
2. GFWList decoder, classifier, safe extractor, fixtures, and diagnostics.
3. Versioned atomic persistence and Store publication/status support.
4. Bounded conditional remote source service and retry scheduling.
5. Directory-watching local source service and reconciliation.
6. Generation-aware Coordinator, supervised compilation, recovery, and
   telemetry.
7. Public Phoenix API and conditional-response tests.
8. Admin telemetry bridge, complete live dashboard, refresh behavior, and
   absolute artifact links.
9. Concurrency hardening, benchmark, deployment integration, and operational
   documentation.

Work uses the user-selected subagent-driven workflow: a fresh implementer per
slice, then specification-compliance and code-quality reviews before the next
slice. The branch is `codex/proxy-rules-full-v1` in
`.trees/proxy-rules-full-v1`.

## Definition of Done

V1 is complete when:

1. The official GFWList is fetched conditionally, size-limited, decoded, and
   safely parsed.
2. Optional local proxy and direct files are watched and reconciled.
3. Both lists compile independently with correct normalization, diagnostics,
   deduplication, and hierarchical folding.
4. All six deterministic artifacts are pre-rendered and atomically published.
5. Cross-list rules and same-domain conflicts remain expressible.
6. Failed fetch, decode, parse, compile, or persistence operations never replace
   a valid artifact with partial or empty state.
7. Last-known-good artifacts survive process and host restart.
8. All six public routes return correct bodies, validators, cache headers, and
   status codes without request-time compilation.
9. The admin dashboard truthfully renders all states, receives live updates,
   provides safe manual refresh, and links to the public endpoint.
10. Telemetry and sampled diagnostics make counts, timings, generations, and
    failure categories observable without leaking complete source data.
11. Unit, property, integration, concurrency, controller, and LiveView tests
    pass within scope.
12. Benchmark and operational documentation are reproducible, and the umbrella
    retains one release, one container, and no additional Phoenix endpoint.
