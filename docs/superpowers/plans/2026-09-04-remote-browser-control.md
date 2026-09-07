# Remote Browser Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the first Remote Browser Control Service described by the 2026-09-04 design and PRD: capability RPC, secure Commander transport, remote browser sessions and workflows, durable central jobs/artifacts, REST/Admin surfaces, and recovery/security verification.

**Architecture:** `gsmlg_commander_protocol` is a process-free shared wire contract. The central `gsmlg_browser` app persists policy, jobs, events, sessions, and artifacts in PostgreSQL and dispatches through the live Commander registry; the remote `gsmlg_browser_agent` owns the authoritative profile lease, safe CDP boundary, action journal, workflow checkpoints, and result outbox. Commander connection restarts never own or terminate browser work.

**Tech Stack:** Elixir 1.18, OTP 28, Phoenix 1.8/LiveView, Ecto/PostgreSQL, Oban, Phoenix PubSub, Phoenix Socket Client, Finch, HTTP WebSocket, DETS, OpenAPI Spex, DuskMoon.

**Scope decisions:**

- The explicit implementation request accepts the otherwise `Draft`/`Proposed` documents.
- CloakBrowser integration targets the authoritative `CloakHQ/CloakBrowser-Manager` v0.1.5 API: Bearer authentication, `/api/health`, `/api/status`, `/api/profiles`, profile status/launch/stop, and proxied CDP endpoints.
- Browser APIs use the existing authenticated Admin actor boundary. They never use the optional public/browser authentication pipelines.
- User idempotency is scoped by actor and workflow; retries create auditable attempts.
- Small-model support is a constrained policy behaviour and validator. No provider is invented because none is specified.
- External tests are tagged and fail closed when explicitly enabled without required Manager/profile credentials; synthetic fixtures never count as real CloakBrowser/Gemini evidence.

---

### Task 1: Shared Commander capability protocol

**Files:**

- Create: `apps/gsmlg_commander_protocol/mix.exs`
- Create: `apps/gsmlg_commander_protocol/lib/gsmlg/commander/protocol/*.ex`
- Create: `apps/gsmlg_commander_protocol/test/gsmlg/commander/protocol/*_test.exs`
- Modify: `mix.exs`

- [x] Write failing tests for strict string-key decoding and encoding of protocol negotiation, capability descriptors, `rpc.request`, `rpc.accepted`, terminal response/error, monotonic `job.event`, and cumulative `event.ack`.
- [x] Verify RED with `mix test apps/gsmlg_commander_protocol/test/` and confirm failures are missing modules/contracts.
- [x] Implement versioned structs and pure validators. The public decoder contract is `decode(map()) :: {:ok, envelope()} | {:error, %{class: String.t(), code: String.t(), details: map()}}`; unknown versions, message types, capability versions, fields, oversized payloads, invalid UUIDs, expired deadlines, and forbidden operation shapes are rejected.
- [x] Verify GREEN with the complete protocol app suite, then run `mix format` on its files.

### Task 2: Generic Commander control plane, application authentication, and mTLS

**Files:**

- Create: `apps/gsmlg_commander/lib/gsmlg/commander/{connection,capability_registry,rpc_router,request_dedup,tls}.ex`
- Create: `apps/gsmlg/lib/gsmlg/command_platform/{rpc_dispatcher,pending_request_registry,replay_cache}.ex`
- Modify: `apps/gsmlg_commander/lib/gsmlg/commander.ex`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/channels/{commander_socket,commander_channel,terminal_channel}.ex`
- Modify: `apps/gsmlg/lib/gsmlg/command_platform/agent_registry.ex`
- Modify: `apps/gsmlg_config/lib/gsmlg/config/{schema,setup}.ex` and checked-in TOML defaults
- Test: corresponding Commander, command-platform, channel, config, and TLS integration tests

- [x] Write failing tests for topic/identity binding, per-node credential ID, signed timestamp window, nonce replay rejection, constant-time signature verification, descriptor registration, same-name reconnect replacement, pending RPC timeout/replay, accepted/response routing, cumulative ACK routing, and payload-safe telemetry.
- [x] Write failing TLS tests for `wss://` enforcement, CA/hostname verification, readable certificate/key files, matching key pair, missing/untrusted client certificate rejection, rotation-triggered connection-only restart, and no insecure fallback.
- [x] Verify both RED sets independently.
- [x] Implement `GSMLG.Commander.Connection` as the only generic channel owner; keep `Terminal` as PTY data compatibility. `AgentRegistry` remains the live-node directory, while pending requests live in a separate process and dedup state survives connection restarts.
- [x] Remove unconditional `Phoenix.SocketClient.Telemetry.attach_debug_handler/0`. Pass verified OTP SSL options through `transport_opts`; certificate rotation restarts only the socket/connection subtree.
- [x] Route any dependency-level telemetry limitation through the required upstream `internal request` issue and mark the local callsite with `WORKAROUND(upstream)`.
- [x] Verify GREEN with protocol, Commander, channel, registry, config, TLS, and log-leak tests.

### Task 3: Remote Browser Agent foundation and authoritative durability

**Files:**

- Create: `apps/gsmlg_browser_agent/mix.exs`
- Create: `apps/gsmlg_browser_agent/lib/gsmlg/browser_agent/{application,supervisor,settings,capability,manager_monitor}.ex`
- Create: `apps/gsmlg_browser_agent/lib/gsmlg/browser_agent/backend*.ex`
- Create: `apps/gsmlg_browser_agent/lib/gsmlg/browser_agent/backends/cloak_browser*.ex`
- Create: `apps/gsmlg_browser_agent/lib/gsmlg/browser_agent/{journal,request_dedup,event_outbox,artifact_store,artifact_outbox,profile_lease,profile_lease_server}.ex`
- Modify: Commander feature/release/config wiring
- Test: `apps/gsmlg_browser_agent/test/gsmlg/browser_agent/` foundation tests and sanitized v0.1.5 fixtures

- [x] Write failing tests for the backend behaviour, v0.1.5 HTTP request paths/Bearer header/status normalization, strict response parsing, sensitive profile-field removal, bounded HTTP bodies/timeouts, immediate durable writes, request-payload collision rejection, monotonic event sequencing/ACK pruning, artifact hash manifests/ACK deletion, and mutually exclusive automation/manual leases.
- [x] Verify RED.
- [x] Implement a single DETS journal owner with versioned composite records and sync-before-reply semantics. Pure `ProfileLease` transitions define acquire, atomic manual handoff, resume, expiry, reconcile, and release; the server only serializes and persists them.
- [x] Implement the CloakBrowser adapter against v0.1.5 without returning `fingerprint_seed`, proxy, `user_data_dir`, CDP URL, token, or other remote-only data from normalized snapshots.
- [x] Verify GREEN, including close/reopen recovery tests and manager error-code mapping.

### Task 4: Safe generic sessions, observations, origin policy, and structured actions

**Files:**

- Create: `apps/gsmlg_browser_agent/lib/gsmlg/browser_agent/cdp/*.ex`
- Create: `apps/gsmlg_browser_agent/lib/gsmlg/browser_agent/{origin_policy,locator,observation,action,postcondition,safe_browser,session,session_runner,session_supervisor}.ex`
- Test: CDP protocol/client, policy, observation, action, session, crash-recovery, and size/redaction suites

- [x] Write failing tests for exact allowed actions/locators, rejected raw CDP/JavaScript/XPath/cookies/storage, default-deny origins and schemes, private/local network denial, redirect revalidation, observation node/depth/byte limits, password redaction, revisions, lease checks, and the pending→validate→execute→observe→complete/unknown journal order.
- [x] Verify RED.
- [x] Implement the CDP client as a supervised socket owner with bounded pending calls and an internal finite method allowlist. Caller input never supplies method names or script bodies.
- [x] Implement `SafeBrowser.execute/3` so stale revisions reject before effects, non-idempotent actions are journaled before dispatch, postconditions prove completion, and uncertain disconnects return `action_outcome_unknown` without automatic retry.
- [x] Implement session open/observe/act/manual handoff/close and reconcile with the remote lease as authority.
- [x] Verify GREEN, including simulated disconnect/crash-after-action cases and the complete M2 suite.

### Task 5: Durable workflows, Gemini contracts, interventions, and model policy

**Files:**

- Create: `apps/gsmlg_browser_agent/lib/gsmlg/browser_agent/workflow*.ex`
- Create: `apps/gsmlg_browser_agent/lib/gsmlg/browser_agent/workflows/gemini/**/*.ex`
- Create: `apps/gsmlg_browser_agent/lib/gsmlg/browser_agent/sites/gemini/**/*.ex`
- Create: `apps/gsmlg_browser_agent/lib/gsmlg/browser_agent/{intervention,manual_handoff,policy,telemetry}.ex`
- Test: pure transition, runner/checkpoint, fixture, extraction, policy, intervention, and restart suites

- [x] Write failing table-driven tests for every Deep Research and YouTube phase, stable report hashing, plan approval, duplicate prompt prevention, unavailable/age/region/title-only outcomes, required result sections, and all human-intervention reason codes.
- [x] Write failing tests that resume must reacquire automation ownership and obtain a fresh observation before any next action.
- [x] Write failing policy tests rejecting unknown actions/origins/locators, stale revisions, scripts, raw CDP, oversized observations, sensitive telemetry metadata, and unbounded error details.
- [x] Verify RED.
- [x] Implement pure `transition(state, observation) :: {:ok, next_state, decision} | {:error, stable_code}` modules and a side-effect runner that checkpoints after each decision. Keep Commander connection and workflow supervisors in independent restart subtrees.
- [x] Produce generic Markdown/HTML/JSON/Sources/Screenshot manifests and retain the remote outbox until central ACK.
- [x] Verify GREEN, including simulated 30-minute disconnect/reconnect, runner restart, Manager restart, duplicate start, and event replay.

### Task 6: Central Browser persistence, orchestration, events, and artifacts

**Files:**

- Create: `apps/gsmlg_browser/mix.exs`
- Create: `apps/gsmlg_browser/lib/gsmlg/browser/**/*.ex`
- Create: `apps/gsmlg/priv/repo/migrations/*_create_browser_control_tables.exs`
- Modify: `apps/gsmlg_storage/lib/gsmlg/storage*.ex` for bounded prepare/finalize upload only
- Modify: Oban/config/release wiring
- Test: schema/constraint, context, dispatcher, reconciler, event-store, artifact-integrity, retention, and worker tests

- [x] Write failing migration/schema tests for BrowserNode/Profile/Session/Job/Event/Artifact constraints, actor-scoped idempotency, retry lineage, one default profile, remote IDs, legal states, positive sequence, and artifact transfer metadata.
- [x] Write failing context/worker tests for transactionally coupled job+Oban insertion, profile row locking, online status merged from `AgentRegistry`, dispatch timeout→unknown→reconcile, cancel/resume/retry/reconcile idempotency, and no blind workflow resubmission.
- [x] Write failing event tests for `(remote_execution_id, sequence)` dedup, gap retention, highest-contiguous ACK after commit, no duplicate PubSub, and replay requests.
- [x] Write failing artifact tests for inline ceilings, exact size/SHA-256/MIME, protected ownership, signed upload expiry/binding, central post-upload hashing, rejected cleanup, and verified-only download.
- [x] Verify RED in database-isolated groups.
- [x] Implement the PostgreSQL-authoritative public `GSMLG.Browser` facade, Oban workers, small unique sweep scheduler, redacted PubSub snapshots, retention, and bounded storage extension.
- [x] Verify GREEN with migrations up/down and all `gsmlg_browser` plus scoped storage tests.

### Task 7: Authenticated REST API and Browser OpenAPI

**Files:**

- Create: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/controllers/browser_*.ex`
- Create: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/{browser_api_spec,open_api/browser_*}.ex`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/router.ex`
- Modify: `apps/gsmlg_admin_web/mix.exs`
- Test: Browser controller, authorization, error mapping, content streaming, and router/spec parity tests

- [x] Write failing tests for every PRD/design node/profile/session/action/job/control/event/artifact route, Admin bearer rejection, actor ownership, typed 404/409/422/503/504 errors, no-store/nosniff content headers, and response redaction.
- [x] Write failing OpenAPI parity/security tests proving every Browser route is documented and no forbidden raw CDP/JavaScript/cookie/storage schema exists.
- [x] Verify RED.
- [x] Implement thin controllers that call only `GSMLG.Browser`; add a protected Browser-only OpenAPI document under the Admin bearer pipeline.
- [x] Verify GREEN with controller and OpenAPI suites.

### Task 8: Admin Browser operations UI and Commander integration

**Files:**

- Create: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/browser_live/**/*.ex`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/{router,admin_menu}.ex`
- Modify: Commander list/show LiveViews for compatible descriptor display and Browser tab
- Test: Browser LiveView, menu, Commander compatibility, accessibility, and connected-browser tests

- [x] Write failing LiveView tests for `/browser`, nodes, profiles, sessions, jobs, new job, job detail, settings, and `/commander/:name/browser`; cover loading/empty/error states, timeline, TLS summary, artifacts, interventions, and cancel/retry/resume/reconcile controls.
- [x] Verify RED while recording the known pre-existing duplicate `admin-sign-out` baseline failure separately.
- [x] Implement DuskMoon pages under `Layouts.app`, stable DOM IDs, compatible descriptor gating, PubSub refresh, actor authorization, redacted summaries, and read-only effective settings.
- [x] Run component/route tests plus a real connected-browser pass for focus, responsive layout, controls, and event updates. Do not suppress or repair unrelated baseline layout failures.

### Task 9: Configuration, releases, hardening, external E2E, and documentation

**Files:**

- Modify: all relevant TOML defaults, `schema.ex`, `setup.ex`, `runtime.exs`, release definitions, `rel/env.sh.eex`, and deployment examples
- Create: sanitized example configuration, operations/recovery/security docs, and tagged external test harnesses
- Test: config fail-closed, release composition, leak scan, restart/failure injection, real TLS, and optional CloakBrowser/Gemini E2E

- [x] Write failing tests for complete central/agent TOML schema, secret references only, enabled-service fail-closed behavior, release app composition, metadata allowlists, and absence of prompt/page/cookie/token/key/cert/payload contents from captured logs.
- [x] Implement configuration defaults and runtime validation. An enabled Browser component refuses invalid security settings; unrelated disabled deployments retain current behavior.
- [x] Document exact NixOS/Podman/Manager v0.1.5 setup, Runtime Secret inputs, SSH WebVNC handoff, certificate rotation, reconcile/outbox recovery, supported API/version matrix, and failure codes.
- [x] Run fresh scoped tests for every changed app, `mix compile --warnings-as-errors`, scoped `mix format --check-formatted`, scoped `mix credo --strict`, `git diff --check`, protocol/API contract scans, and sensitive-output scans.
- [ ] When external credentials/host are available, run tagged real NixOS + Podman + CloakBrowser + Gemini, connection-loss, central restart, Manager restart, artifact, manual handoff, and certificate-rotation E2E. Record exact evidence; never report fixture tests as real E2E.
- [x] Re-read every FR/NFR/SR/AS/Definition-of-Done item and map it to code plus fresh evidence. Any unmet externally gated item is reported as a blocker, not completion.
