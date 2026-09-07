# Remote Browser Control Verification

This document traces the Remote Browser Control implementation to the
[design](2026-09-04-remote-browser-control-design.md),
[PRD](2026-09-04-remote-browser-control-prd.md), and
[implementation plan](../superpowers/plans/2026-09-04-remote-browser-control.md).
It records local automated evidence as of 2026-09-06. The tested base commit was
`e920bceb4def8826369a6c35210d28ae87d87d20`; the feature worktree contained
uncommitted tracked and untracked changes, so no commit SHA represents the
complete tested snapshot. It is not production acceptance evidence.

## Status legend

On 2026-09-07, the requesting user accepted implementation completion and
explicitly deferred real E2E acceptance to deployment testing. The external
items below remain unrun and describe the deployment test checklist; they do
not block completion of this implementation task or the requested GitHub release.

| Status | Meaning |
| --- | --- |
| Locally verified | The implementation is covered by passing local unit, integration, database, controller, or LiveView tests. Synthetic Manager/CDP/Gemini fixtures may be involved. |
| Locally verified; external pending | Local contracts and failure injection pass, but the requirement also needs the real NixOS/Podman/CloakBrowser/Gemini or production-WSS matrix. |
| External pending | Only the opt-in real-environment harness can close the acceptance item. It was not run for this verification. |
| Tooling blocked | A repository-wide verification command is stopped by a pre-existing out-of-scope file. |

Passing fixture tests must not be described as real CloakBrowser, Gemini,
deployment, performance, 30-minute-disconnect, or certificate-rotation proof.

## Implementation surfaces

| Boundary | Concrete implementation | Primary local evidence |
| --- | --- | --- |
| Shared wire protocol | `apps/gsmlg_commander_protocol/lib/gsmlg/commander/protocol/` | `apps/gsmlg_commander_protocol/test/gsmlg/commander/protocol/` |
| Central Commander control plane | `apps/gsmlg/lib/gsmlg/command_platform/`, `apps/gsmlg_admin_web/lib/gsmlg/admin_web/channels/commander_channel.ex`, `commander_socket.ex` | `apps/gsmlg/test/gsmlg/command_platform/control_plane_test.exs`, `apps/gsmlg_admin_web/test/gsmlg/admin_web/channels/commander_control_channel_test.exs`, `commander_socket_auth_test.exs` |
| Remote Commander | `apps/gsmlg_commander/lib/gsmlg/commander/connection.ex`, `rpc_router.ex`, `request_dedup.ex`, `tls.ex`, `transport.ex` | `apps/gsmlg_commander/test/{connection,rpc_router,request_dedup,tls,transport_reconnect}_test.exs` |
| Browser Agent foundation | `apps/gsmlg_browser_agent/lib/gsmlg/browser_agent/{capability,manager_monitor,journal,profile_lease_server}.ex`, `backends/cloak_browser*` | `foundation_test.exs`, `cloak_browser_test.exs`, `journal_outbox_test.exs`, `journal_retention_test.exs`, `profile_lease_test.exs` |
| Safe sessions and CDP | `apps/gsmlg_browser_agent/lib/gsmlg/browser_agent/{session_supervisor,safe_browser,origin_policy,observation,action,locator,postcondition}.ex`, `cdp/` | `safe_contracts_test.exs`, `safe_browser_test.exs`, `session_test.exs`, `cdp_*_test.exs` |
| Remote workflows | `apps/gsmlg_browser_agent/lib/gsmlg/browser_agent/{workflow_runner,workflow_supervisor,workflow_artifacts}.ex`, `workflows/gemini/`, `sites/gemini/` | `gemini_workflow_test.exs`, `workflow_contract_test.exs`, `workflow_journal_test.exs`, `workflow_lifecycle_test.exs` |
| Central Browser service | `apps/gsmlg_browser/lib/gsmlg/browser.ex`, schemas, `event_store.ex`, `artifact_service.ex`, `commander_bridge.ex`, workers | `apps/gsmlg_browser/test/gsmlg/browser/` |
| Artifact storage | `apps/gsmlg_storage/lib/gsmlg/storage.ex`, `s3_client.ex`; dedicated upload ingress under `gsmlg_admin_web` | `upload_reservation_test.exs`, `artifact_service_test.exs`, `browser_artifact_upload_ingress_test.exs` |
| REST and OpenAPI | `apps/gsmlg_admin_web/lib/gsmlg/admin_web/browser_api/`, `controllers/browser_api/`, `browser_api_spec.ex`, `router.ex` | `apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/browser_api/` |
| Admin UI | `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/browser_live/index.ex`, Commander Browser tab/menu integration | `browser_live_test.exs`, `commander_live/show_live_test.exs`, menu/component tests |
| Configuration and release | `apps/gsmlg_config/lib/gsmlg/config/{loader,schema,setup}.ex`, TOML defaults/examples, root release definitions | Browser config/setup/fail-closed tests and release-composition tests |

## Functional requirements

Every PRD functional requirement is included in one inclusive row below.

| Requirements | Implementation and evidence | Status |
| --- | --- | --- |
| FR-001–FR-010 — versioned descriptor, generic control channel, `browser.control/v1`, strict versions and request IDs, Accepted IDs, idempotency, monotonic events, dedup/ACK | Protocol envelope/capability/event modules; Commander `Connection`, `RPCRouter`, `RequestDedup`; central pending/replay registries and `EventStore`. Covered by protocol tests, Commander connection/dedup/router tests, control-plane tests, and `event_store_test.exs`. | Locally verified |
| FR-011–FR-016 — node discovery, four states, versions, limits, default node, Registry-authoritative online state | `GSMLG.Browser.list_nodes/2` discovers and upserts negotiated descriptors, refreshes bounded `manager.status`, and merges AgentRegistry liveness; central configuration supplies `default_node`. Covered by Browser context tests and connected BrowserLive tests. | Locally verified; external pending for a deployed node appearing within 10 seconds |
| FR-017–FR-024 — profile list/redaction/sync/status/launch/stop/configuration and exclusive automation/manual lease | CloakBrowser adapter, central Profile schema/context, actor-explicit `configure_profile/3`, canonical origin policy, row locks/default index, and remote `ProfileLeaseServer`. Covered by CloakBrowser fixture tests, Browser context/schema tests, API/LiveView profile tests, and lease concurrency tests. | Locally verified; real Manager profile discovery pending |
| FR-025–FR-030 — session create selection/identity/states/close and timeout reconcile | Remote `SessionSupervisor`/runner and central Session/context/proxy with exact session RPCs and persisted IDs/revision/deadline. Covered by session, capability, central session-context, orchestration, and controller tests. | Locally verified |
| FR-031–FR-037 — bounded semantic observation, revision, sensitive-value redaction, permissioned screenshot | `Observation`, CDP adapter/client, `SafeBrowser`, and public presenter allowlists. Covered by safe-contract, CDP, SafeBrowser, presenter, and session tests. | Locally verified |
| FR-038–FR-048 — finite actions, action ID/revision, semantic locators, no raw CDP/JS, lease validation, pending journal, postcondition, unknown outcome | `Action`, `Locator`, `Postcondition`, `SafeBrowser`, durable Journal, and typed central/API lowering. Tests cover the exact vocabulary, stale rejection before effects, action journal ordering, crash/disconnect ambiguity, and `stale_observation`/`action_outcome_unknown`. | Locally verified |
| FR-049–FR-053 — per-profile/session allowlist, navigation/redirect recheck, unsafe schemes/private network denial, unknown-origin fail closed | Central `GSMLG.Browser.Origin` and remote `OriginPolicy`; CDP request interception reauthorizes redirects and network peers. Covered by `safe_contracts_test.exs`, `safe_browser_test.exs`, and `cdp_client_test.exs`. | Locally verified |
| FR-054–FR-061 — versioned remote workflows, checkpoint per transition, disconnect continuation, event replay, central reconcile, controls/deadline, idempotency | Remote workflow contract/runner/supervisor/journal/outbox and central Dispatch/Reconcile/Event workers. Covered by workflow journal/lifecycle/capability tests and central orchestration/event tests. | Locally verified; real disconnect/restart duration pending |
| FR-062–FR-067 — Deep Research v1 inputs/phases, guarded prompt submission, stable report hash, Markdown/JSON/Sources | `workflows/gemini/deep_research.ex`, versioned UI contract, workflow runner/artifact builder. Table-driven fixture tests cover all phases, intervention/failure states, three stable hashes, required sections, and artifact manifests. | Locally verified; real Gemini run pending |
| FR-068–FR-072 — YouTube v1 profiles, unavailable/restricted/inaccessible/title-only detection, structured outputs | `workflows/gemini/youtube_analysis.ex` and UI contract. `gemini_workflow_test.exs` covers the finite profiles, video identity, grounding, restrictions, and required output fields. | Locally verified; real YouTube/Gemini run pending |
| FR-073–FR-078 — waiting-human reasons, manual handoff exclusivity, automation rejection, fresh-observation resume, SSH/WebVNC operational path | `Intervention`, manual acquire/release RPCs, lease transitions, workflow resume path, Browser facade/API/UI, and the operations runbook. Covered by lease, workflow lifecycle, event store, session context, controller, and LiveView tests. | Locally verified; real SSH/WebVNC handoff pending |
| FR-079–FR-086 — durable jobs/events/states/result manifest, strict artifacts, inline/upload modes, outbox ACK discipline, authorized download | Central schemas/state machines/EventStore/ArtifactService/workers, remote event/artifact outboxes, Storage reservations, upload ingress, and content controllers. Tests cover gaps, changed duplicates, ACK-after-commit, completion ordering, exact MIME/size/hash, one-use uploads, restart recovery, verified-only/range downloads, and durable ACK retry. The shared protocol is authoritative for `.bin`, `.pdf`, `.json`, `.html`, `.md`, `.txt`, `.png`, `.jpg`, and `.jpeg` downloads. | Locally verified; real large upload/download pending |
| FR-087–FR-091 — dashboard, resource pages, Commander Browser tab, job timeline/intervention/artifacts, controls | BrowserLive routes and DuskMoon views, menu/Commander descriptor integration, invalidation-only PubSub. Covered by BrowserLive, Commander LiveView, component, route, and API tests, plus a connected real-Chrome desktop/mobile pass. | Locally verified; deployed real-event-source pass pending |
| FR-092–FR-098 — configurable client cert/key, WSS/peer/hostname validation, preflight/key match, no fallback, application auth, connection-only rotation | Commander `TLS`, `Transport`, `Connection`, socket authentication, live redacted TLS-expiry heartbeats, and separated Browser supervision. Local TLS listener, invalid credential, heartbeat allowlist, transport, auth, and stable rotation tests cover these boundaries. | Locally verified; production WSS handshake and live rotation pending |
| FR-099–FR-102 — unified TOML, secret references, runtime injection, fail closed | Config loader/schema/setup, checked defaults/examples, environment/file references, Browser/Agent enabled gates. Covered by Browser config/setup/fail-closed and release configuration tests. | Locally verified; deployment secret injection pending |

### Functional requirement ID index

The grouped rows above describe subsystem evidence. This index makes every
individual obligation explicit:

- FR-001: `Capability` is versioned; FR-002: `Connection` owns registration,
  heartbeat, and capability publication; FR-003: the Agent registers
  `browser.control/v1`; FR-004: descriptor validation requires backend,
  operations, limits, and workflows; FR-005: negotiation rejects incompatible
  protocol/capability versions.
- FR-006: every RPC carries a UUID request ID; FR-007: long workflow starts
  return `RPCAccepted` with a remote execution ID; FR-008: request, cancel,
  resume, and reconcile each have replay/idempotency coverage in request-dedup,
  workflow-lifecycle, and central orchestration tests; FR-009: EventOutbox
  allocates monotonic sequence numbers; FR-010: EventStore deduplicates changed
  and exact replays and ACKs only committed contiguous sequence.
- FR-011: Browser lists persisted and live capable nodes; FR-012: Node validates
  online/degraded/offline/disabled; FR-013: bounded Agent/backend/browser
  versions come from descriptor plus `manager.status`; FR-014: descriptor
  limits expose profile/session/workflow capacity; FR-015: validated central
  `default_node` resolves admission; FR-016: AgentRegistry, not a DB flag, is
  the live online source.
- FR-017: the backend lists profiles; FR-018: adapter/Sanitizer retain only safe
  profile metadata; FR-019: `sync_profiles/2` persists normalized snapshots;
  FR-020: status/list, launch, and stop use exact RPC operations; FR-021:
  leased/manual profiles reject direct mutation/stop; FR-022:
  `configure_profile/3` sets enabled/default/canonical origins; FR-023: one
  active lease is serialized remotely; FR-024: automation and manual authority
  are mutually exclusive.
- FR-025: actor APIs create sessions; FR-026: requests require node, profile,
  mode, and origins; FR-027: central/remote session, lease, and revision
  identities are persisted/validated; FR-028: Session validates the finite
  state set; FR-029: explicit close is wired end to end; FR-030: ambiguous
  close/timeout becomes unknown/orphaned and reconciles rather than assuming
  closure.
- FR-031: observe returns a structured Observation; FR-032: its allowlist
  includes URL, origin, title, loading state, page kind, alerts, and controls;
  FR-033: semantic/accessibility nodes are finite; FR-034: revision is
  monotonic; FR-035: sensitive inputs are redacted; FR-036: depth, node, text,
  and byte limits are tested; FR-037: screenshot requires permission and its
  bytes/manifest are bounded in SafeBrowser tests.
- FR-038: Action validates exactly navigate/click/focus/fill/insert-text/key/
  select/scroll/wait/extract/screenshot/download; FR-039: action ID is required
  and deduplicated; FR-040: expected revision is supported; FR-041: mismatch
  returns `stale_observation` before effects; FR-042: semantic locators and
  observation node IDs are supported; FR-043: no public raw-CDP operation;
  FR-044: no public arbitrary-JavaScript operation.
- FR-045: lease is checked before action effects; FR-046: non-idempotent intent
  is durably pending first; FR-047: completion requires postcondition or fresh
  observation; FR-048: ambiguous effects become durable
  `action_outcome_unknown` and are never blindly retried.
- FR-049: configured profile/session origin allowlists are required; FR-050:
  scheme and origin are checked before navigation; FR-051: redirects and actual
  network requests are rechecked; FR-052: JavaScript/data/file/local/private
  targets are denied; FR-053: unknown origin fails or pauses with a stable
  policy/intervention outcome.
- FR-054: workflows have explicit ID/version contracts; FR-055: execution is in
  Browser Agent; FR-056: runner decisions checkpoint durably; FR-057: workflow
  supervision is independent of Commander; FR-058: unacked EventOutbox entries
  replay after owner registration; FR-059: central workers reconcile nonterminal
  jobs; FR-060: cancel/resume/reconcile enforce absolute deadlines; FR-061:
  workflow start idempotency returns the existing execution and rejects changed
  fingerprints.
- FR-062: Deep Research v1 exists; FR-063: its exact schema covers prompt,
  locale, research scope, sections, and auto-approval; FR-064: fixture
  transitions cover login, plan, research, report, quota, and error; FR-065:
  prompt submission uses pending action/postcondition recovery; FR-066: report
  extraction requires three stable canonical hashes; FR-067: required manifests
  are Markdown, structured JSON, and Sources.
- FR-068: YouTube Analysis v1 exists; FR-069: all five analysis profiles are
  validated; FR-070: unavailable, age/region restricted, and inaccessible
  video outcomes are tested; FR-071: title/description-only evidence cannot
  complete; FR-072: result schema covers timeline, arguments, evidence, action
  items, and uncertain claims.
- FR-073: job/workflow state includes waiting-human; FR-074: Intervention has a
  finite reason code and Admin instruction; FR-075: acquire atomically converts
  automation to manual authority; FR-076: automatic actions fail while manual
  authority is held; FR-077: resume reacquires and observes before deciding;
  FR-078: the runbook defines SSH tunnel plus backend WebVNC, while its real
  exercise remains external.
- FR-079: central schemas persist jobs/events; FR-080: JobState enforces the
  required finite state graph and terminal immutability; FR-081: reconciled job
  result is a bounded generic manifest; FR-082: Artifact requires kind, MIME,
  filename, size, and SHA-256; FR-083: whole encoded inline responses are
  ceiling-checked; FR-084: large content uses dedicated signed PUT;
  FR-085: remote content/outbox is deleted only after central ACK; FR-086:
  actor-authorized list/get/full/range download is implemented.
- FR-087: `/browser` is the dashboard; FR-088: node/profile/session/job views and
  artifact views within job detail are implemented; FR-089: negotiated
  compatible Commander nodes get a Browser tab; FR-090: job detail shows phase,
  event timeline, intervention, authorized chat URL, and artifacts; FR-091:
  cancel/retry/resume/reconcile controls call the actor-explicit facade.
- FR-092: Commander accepts client chain/private-key paths; FR-093: enabled mTLS
  requires WSS; FR-094: peer, CA, hostname, and SNI verification are configured;
  FR-095: files, validity, and key match are checked before connection; FR-096:
  failures have no insecure fallback; FR-097: HMAC application identity and
  capability authorization remain mandatory; FR-098: rotation restarts only
  the connection subtree.
- FR-099: central and Agent options are in the unified TOML schema; FR-100:
  checked files contain only secret references/paths; FR-101: environment and
  systemd-credential inputs are documented and validated; FR-102: enabled
  components reject missing or unsafe configuration without crashing or
  falling back.

## Non-functional requirements

| Requirements | Implementation and evidence | Status |
| --- | --- | --- |
| NFR-001–NFR-004 — 30-minute continuity, at-least-once/dedup, restart reconcile, no blind action retry | Independent workflow supervisor, durable checkpoints/journals/outboxes, cumulative ACK, central reconcile workers, and pending-action recovery tests. | Locally verified; 30-minute and real process-restart matrix pending |
| NFR-005–NFR-007 — inventory under 2 s, Observe under 3 s, Action dispatch under 2 s at P95 | Bounded local deadlines exist. `browser_control_e2e_test.exs` collects 20–100 live samples and enforces the three targets. | External pending; no P95 claim is made |
| NFR-008 — default observation at most 1 MiB | Agent settings and Observation byte/node/depth truncation; multibyte and oversized tests. | Locally verified |
| NFR-009–NFR-013 — data minimization, no dangerous public APIs/log bodies, policy on every navigation, production mTLS support | Remote-only Manager/CDP/profile secrets; central Sanitizer and presenter allowlists; finite action/OpenAPI schemas; OriginPolicy/CDP interception; Commander TLS. Covered by redaction, public-contract, captured-log, policy, and TLS tests. | Locally verified; real full-log scan and production TLS pending |
| NFR-014–NFR-017 — backend behaviour, independently versioned UI contract/workflow, pure transitions/fixtures, backward-compatibility and incompatible-version rejection | `Backend` behaviour/CloakBrowser adapter, Gemini UI contract and workflow modules, pure transition tests, protocol round-trip/version-rejection tests, and legacy PTY compatibility tests. | Locally verified |
| NFR-018 — correlation IDs for jobs, sessions, actions, and RPCs | Central/remote schemas and wire envelopes carry central/remote job IDs, session IDs, action IDs, request IDs, and idempotency keys. Tests reject identity mismatches and collisions. | Locally verified |
| NFR-019 — phase duration, failure, intervention, reconcile metrics | Central and remote Browser telemetry modules emit allowlisted scalars; telemetry tests cover workflow phase/intervention/failure, reconcile duration/outcome, and artifact transfer status. | Locally verified |
| NFR-020 — stable TLS/Manager/CDP/UI-contract errors | Six-field protocol/public error models and bounded mapping in TLS, backend, CDP, workflow, facade, and API response modules. Exhaustive response and subsystem error tests apply. | Locally verified |

### Non-functional requirement ID index

- NFR-001: independent remote supervision and durable state target the 30-minute
  disconnect; NFR-002: event/result delivery is at-least-once with dedup and
  cumulative ACK; NFR-003: central, Commander, Agent, and Manager each have an
  explicit reconcile path; NFR-004: non-idempotent action recovery never blindly
  retries. The real duration/restart proof remains external.
- NFR-005: the external sampler enforces inventory P95 below 2 seconds;
  NFR-006: it enforces Observe P95 below 3 seconds; NFR-007: it enforces Action
  dispatch P95 below 2 seconds. None of these P95 measurements was run here;
  NFR-008: local Observation tests enforce the default 1 MiB ceiling.
- NFR-009: central persistence sanitizers reject cookie/storage/token/CDP/path
  fields; NFR-010: public schema has no raw CDP/JS/cookie/storage operation;
  NFR-011: local log tests reject prompt/page/artifact-body canaries; NFR-012:
  all initial/redirect/network navigation passes OriginPolicy; NFR-013:
  Commander supports peer-verifying client mTLS, with real production WSS
  pending.
- NFR-014: Browser backends implement a behaviour; NFR-015: workflow and site UI
  contract versions are separate; NFR-016: table-driven transition modules are
  pure and fixture-tested; NFR-017: protocol round-trip/rejection tests plus
  legacy PTY compatibility tests cover supported compatibility and explicit
  rejection of incompatible versions.
- NFR-018: UUID/correlation identity is mandatory across job/session/action/RPC;
  NFR-019: allowlisted phase, failure, intervention, reconcile, and artifact
  metrics have local tests; NFR-020: TLS/Manager/CDP/UI-contract paths return
  bounded stable codes.

## Security requirements

| Requirements | Implementation and evidence | Status |
| --- | --- | --- |
| SR-001–SR-003 — remote credentials/Manager boundary/exclusive lease | Profile/Manager secrets remain in Browser Agent settings and adapter; Manager URL is loopback-only; remote lease is authoritative and serialized. Redaction, settings, adapter, and concurrent lease tests cover this. | Locally verified; deployed network binding pending |
| SR-004–SR-007 — default-deny origins; no CDP/JS/cookie/storage/password reads; human auth never recorded | OriginPolicy, finite Action/CDP adapters, Observation redaction, intervention state machine, central sanitizers, closed OpenAPI schemas, and captured-log tests. | Locally verified; real log interval scan pending |
| SR-008–SR-010 — application/capability authorization, mTLS, no TLS/RPC credentials in telemetry | Identity-bound Commander socket/channel, negotiated capability ownership, mTLS transport, recursive telemetry allowlists. Covered by socket/channel, connection, TLS, transport, and log-canary tests. | Locally verified; real public listener pending |
| SR-011 — short-lived owner/artifact-bound SHA-verified upload | Dedicated header-token PUT ingress binds each artifact to exactly one job or session owner plus token digest/expiry/exact headers; Storage reservation, rehash/MIME verification, cleanup, and ACK-after-commit retry are covered by ArtifactService, Storage, ingress, and transfer tests. | Locally verified; real large transfer pending |
| SR-012 — authorized Chat URL, screenshot, and artifact access | Strict `Job.chat_url` host validation and trusted RPC population; actor-owned session/job/artifact facade; session-authenticated content controller; screenshot permission checks. Covered by chat URL, ownership, presenter, controller, LiveView, and artifact tests. | Locally verified |

### Security requirement ID index

- SR-001: profile credentials remain remote; SR-002: enabled Agent settings
  require a loopback Manager URL and deployment binds it to loopback; SR-003:
  ProfileLeaseServer is the serialized exclusive authority.
- SR-004: OriginPolicy is default deny; SR-005: raw CDP/JavaScript is absent from
  the public contract; SR-006: cookie/storage/password reads are absent or
  redacted; SR-007: human-auth content is represented only by a stable
  intervention reason and instruction.
- SR-008: RPC requires Commander identity plus negotiated capability ownership;
  SR-009: Commander implements client-certificate mTLS; SR-010: TLS and RPC
  telemetry is recursively allowlisted and canary-tested.
- SR-011: upload capabilities are short-lived and bind artifact plus exactly one
  job/session owner, method,
  headers, size, and SHA-256; SR-012: chat URL, screenshots, and artifact content
  are served only through actor/session-authorized presenters/controllers.

## Acceptance scenarios

| Scenario | Local evidence | Release status |
| --- | --- | --- |
| AS-001 Node discovery | Connected AgentRegistry/BrowserLive test verifies automatic `browser.control/v1`, backend, and limits visibility without pre-seeding. | Locally verified; deployed 10-second observation pending |
| AS-002 Profile confidentiality | CloakBrowser normalization, central Sanitizer/schema, presenter, and canary tests reject remote-only keys. | Locally verified; real profile response/database inspection pending |
| AS-003 Generic action | Session/SafeBrowser/context/controller tests open, observe, click an observation node ID, and return a higher revision. | Locally verified; real click pending |
| AS-004 Stale action prevention | SafeBrowser and API tests return typed `stale_observation` before effects. | Locally verified |
| AS-005 Exclusive lease | Remote serialized concurrency and central row-lock tests allow one contender and return `profile_busy` to the other. | Locally verified; two-real-actor run pending |
| AS-006 Deep Research continuity | Simulated Commander loss, replay, checkpoint, and outbox tests pass. | External pending for real 30-minute interruption and final result |
| AS-007 Duplicate request | Request/workflow journal and central idempotency tests return the same execution and reject changed fingerprints. | Locally verified |
| AS-008 Crash after submit | Pending-action and workflow recovery tests distinguish not-dispatched/completed/uncertain without duplicate submit. | Locally verified; real browser crash pending |
| AS-009 Human login | Intervention/manual lease/resume tests enforce paused automation and fresh observation. | External pending for real login/2FA/CAPTCHA and SSH/WebVNC |
| AS-010 Artifact integrity | ArtifactService/Storage/download tests verify Markdown/Sources size, SHA-256, MIME, ownership, commit, and ACK ordering. | Locally verified; real workflow artifact transfer pending |
| AS-011 mTLS connection | Local TLS listener accepts trusted and rejects missing/untrusted client identities. | External pending for deployed WSS listener |
| AS-012 Certificate rotation | Local rotation tests restart only the connection and retry failed restarts; supervisors are separated. | External pending for live workflow continuity during rotation |
| AS-013 Sensitive log protection | Captured telemetry/log/PubSub tests use canaries and allowlisted metadata. | External pending for complete deployed log scan |

## Definition of Done

| DoD | Evidence and disposition |
| --- | --- |
| 1. Commander Capability RPC | Implemented and locally verified by protocol/control-plane/Commander suites. |
| 2. Browser Agent connects to CloakBrowser Manager | Adapter and sanitized v0.1.5 fixtures are locally verified; real Manager harness is unrun. Not externally accepted. |
| 3. Node/Profile/Session/Job/Event/Artifact API | Actor-explicit facade plus exact 25-operation Browser REST/OpenAPI surface are locally verified. |
| 4. Generic Observe/Act Session | Locally verified through Agent, central, controller, and stale-revision tests; real browser session is unrun. |
| 5. Profile Lease and Action Revision | Locally verified, including concurrency, manual exclusivity, stale rejection, and recovery. |
| 6. Deep Research and YouTube Analysis | Versioned fixture/state-machine contracts are locally verified; real Gemini executions are unrun. Not externally accepted. |
| 7. Commander/Central disconnect recovery | Simulated durable recovery is locally verified; real 30-minute/restart matrix is unrun. Not externally accepted. |
| 8. Human Intervention and Resume | Local state/lease/fresh-observation flow is verified; real SSH/WebVNC authentication handoff is unrun. |
| 9. Artifact verification and download | Local inline/upload/reservation/rehash/ACK/content tests pass; real full-stack transfer is unrun. |
| 10. Configurable Commander mTLS client | Configuration and local TLS/rotation tests pass; production WSS harness is unrun. |
| 11. Complete Admin operational view | Routes, loading/empty/error states, inventories, timeline, intervention, artifacts, controls, and Commander tab are locally verified. A connected real-Chrome pass covered desktop, mobile, light/dark rendering, and LiveSocket connectivity; deployed real-event updates remain external. |
| 12. Security and sensitive-log tests | Local contract/canary tests exist and pass in their scoped suites; full deployed multi-service log scan is unrun. |
| 13. Real NixOS + Podman + CloakBrowser E2E | **External pending. This verification does not claim it passed.** |
| 14. Design/config/deployment/failure documentation | Design, PRD, examples, operations, security, and this verification trace exist. External evidence must be appended after an actual acceptance run. |

The feature is locally implemented and substantially locally verified, but the
PRD Definition of Done is not closed until DoD 13 and the external portions of
DoD 2, 4, 6–12 pass on the dedicated environment.

## Local automated evidence

The following commands were run from the feature worktree on 2026-09-06.
External tests were excluded.

`<test-db-url>` below denotes the local test database URL; its value is omitted
from this document. Child-app commands were run from their app directories;
database, Admin, asset, migration, and release commands were run from the
umbrella root.

```sh
# Child-app suites
mix test
mix test --max-cases 1              # Browser Agent

# Database-backed and focused umbrella suites
DATABASE_URL='<test-db-url>' mix test <scoped feature test files>

# Strict child-app compile gates
MIX_ENV=test mix compile --force --warnings-as-errors

# Production artifacts and assets
mix assets.deploy
MIX_ENV=prod mix release gsmlg_commander --overwrite
MIX_ENV=prod mix release gsmlg_umbrella --overwrite
```

| Scope and command | Result |
| --- | --- |
| V1 — protocol | 50 tests, 0 failures. |
| V2 — Commander | 66 tests, 0 failures, 1 external test excluded. Certificate-rotation timing was repeated 20 times without failure. |
| V3 — central Commander control plane | 13 tests, 0 failures. |
| V4 — Browser Agent | 213 tests, 0 failures, 3 external tests excluded, run serially. The hard-link no-replace timing test was repeated 20 times without failure. |
| V5 — central Browser | 70 tests, 0 failures. Artifact concurrency was repeated 20 times without failure. |
| V6 — Browser configuration | 97 tests, 0 failures. |
| V7 — Storage upload reservation | 2 tests, 0 failures. |
| V8 — shared components | 3 tests, 0 failures. |
| V9 — focused Admin feature and modified-regression set | 110 tests, 0 failures. The OpenAPI subset was also run directly: 3 tests, 0 failures. It proves normalized 25-operation router parity and runtime/schema casting parity for canonical origins, nullable results, and artifact response contracts. |
| V10 — strict compilation | Forced `--warnings-as-errors` compilation passed for `gsmlg_commander_protocol`, `gsmlg_commander`, `gsmlg_browser_agent`, `gsmlg_browser`, `gsmlg`, `gsmlg_config`, `gsmlg_storage`, and `gsmlg_component`. |
| V11 — migrations | The three Browser migrations completed isolated-schema up/down/up and the temporary schema was removed. |
| V12 — assets | Admin and public Tailwind/Bun production assets built successfully. |
| V13 — production releases | Commander tarball: 14,346,287 bytes, SHA-256 `bb3494a9a5f8813dbae2595881d97b2f260fb8b57253de12eb2b84eb2ef66066`. Umbrella tarball: 55,062,145 bytes, SHA-256 `2aa6fcaff17100fd41263f04e5b73bbdf9f348bedb7dd09693b8fb64af0147f7`. These prove local composition/build only, not deployment. |
| V14 — connected real Chrome | `/browser` and `/browser/jobs/new` rendered with a connected LiveSocket at desktop and 390×844 mobile viewports, in light/dark checks. Lighthouse accessibility was 84–85 and best practices 100; remaining findings are the documented pre-existing Admin shell/appbar/menu baseline, not the Browser active-section styling. |
| V15 — final static gates | Scoped `mix format --check-formatted` passed; scoped Credo checked 215 source files with no issues; `git diff --check` and a changed-file trailing-whitespace scan passed. FR/NFR/SR/AS identifier comparison found no missing traceability entry, and the public Browser/OpenAPI contract scan found no raw CDP, JavaScript, XPath, cookie, or browser-storage operation. A credential-pattern scan found only documented placeholder values. |

## External acceptance matrix — not run

All three harnesses are tagged `external: true`, require
`BROWSER_E2E_CONFIRM_REAL=yes`, and fail closed when credentials or dedicated
resources are absent. None was run for this verification. No
`BROWSER_E2E_*` or `CLOAKBROWSER_*` environment variable was present in the
verification workspace, and no dedicated host was supplied.

| Harness | What it must prove before release |
| --- | --- |
| `apps/gsmlg_browser_agent/test/external/cloak_browser_e2e_test.exs` | Real NixOS host, pinned Podman image `localhost/cloakbrowser-manager:v0.1.5`, Manager health/version, redacted profile discovery, and loopback authenticated CDP connection. |
| `apps/gsmlg_commander/test/external/commander_mtls_e2e_test.exs` | Real WSS upgrade, hostname/CA verification, Commander application authentication and capability negotiation; trusted client accepted, missing/untrusted client certificates rejected. |
| `apps/gsmlg_admin_web/test/external/browser_control_e2e_test.exs` | Two-actor lease contention; real Observe/Act/stale revision; P95 samples; Deep Research and YouTube completion; human handoff/resume; verified downloads; 30-minute Commander loss; central/Agent/Manager restarts; certificate rotation; contiguous event history; full sensitive-log scan. |

Follow [Remote Browser Control Operations](remote-browser-control-operations.md)
for required environment variables, failure-injector semantics, NixOS/Podman
setup, SSH/WebVNC handoff, evidence retention, and exact commands. Follow
[Remote Browser Control Security](remote-browser-control-security.md) for trust
boundaries and release security checks.

An external run must record release SHAs, Manager source/image identity, host,
timestamps, fixed injected phases, sanitized job/session/artifact identifiers,
highest contiguous event sequence, artifact sizes/hashes, terminal outcomes,
and stable failure codes. It must never record prompts, page bodies, cookies,
storage, credentials, raw CDP URLs, signed targets, upload tokens, or artifact
bodies.

## Known repository-wide blockers

These are pre-existing and outside the Remote Browser Control scope. They are
reported rather than modified.

1. `mix compile --warnings-as-errors` stops at
   `apps/gsmlg_gao_note/lib/gsmlg/gao_note/attachments.ex:711`: Dialyzer/compiler
   reports an unreachable `{:error, reason}` clause for `storage_source/1`.
2. Additional warnings observed while compiling `gsmlg_admin_web` strictly are:
   unused `destination` at
   `apps/gsmlg_admin_web/lib/gsmlg/admin_web/gao_note_attachment_temp.ex:201`,
   non-grouped `handle_event/3` clauses at
   `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/index.ex:558`,
   and deprecated `<%#` syntax at the same file's line 2312.
3. Root `mix format --check-formatted` cannot parse
   `apps/gsmlg_admin_web/test/gsmlg/admin_web/gao_note_markdown_attribute_safety_test.exs:36`
   because of a pre-existing mismatched delimiter.

Until the external matrix passes and the repository-wide gates can run cleanly,
this document is a traceability and local-verification record, not a release
approval.
