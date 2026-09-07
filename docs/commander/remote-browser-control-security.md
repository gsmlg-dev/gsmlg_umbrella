# Remote Browser Control Security

## Boundary summary

The central service never connects to CloakBrowser Manager or CDP. The remote
Browser Agent is the only component allowed to reach Manager on loopback and
the only component that sees a CDP URL, Manager token, profile directory, or
browser authentication state.

The authorization chain is:

```text
TLS server verification
-> production Commander client mTLS
-> per-node Commander application credential
-> negotiated browser.control/v1 capability
-> central actor ownership and node/profile policy
-> remote profile lease
-> origin, locator, action, revision, and postcondition validation
```

Failure at any layer denies the operation. mTLS supplements, but never replaces,
the per-node application signature and capability checks.

## Public surfaces

- `/api/browser/**` uses the Admin access Bearer boundary. Missing, malformed,
  invalid, expired, revoked, and wrong-token-type credentials return the same
  bounded authentication error.
- Browser sessions, jobs, events, and artifacts are actor-owned. A foreign ID
  is indistinguishable from an absent ID.
- `PUT /browser-artifact-uploads/:artifact_id` is not an actor API. It accepts
  one short-lived, single-artifact upload capability in the
  `x-browser-upload-token` header and exact content headers. It is intentionally
  absent from the Browser OpenAPI/catalog resource list.
- Admin LiveView pages use the existing authenticated browser session and
  client-certificate boundary. Artifact links use a session-authorized content
  controller; they never put a Bearer token in a URL.
- CloakBrowser Manager and its CDP/WebVNC endpoints bind remote loopback only.

All Browser JSON responses use `Cache-Control: no-store` and
`X-Content-Type-Options: nosniff`. Verified artifact responses additionally use
a safe server-selected content disposition and support bounded byte ranges.

## Operations intentionally absent

No public schema, controller, workflow decision, or model policy exposes:

- raw CDP commands or URLs;
- arbitrary JavaScript or script evaluation;
- cookie, Local Storage, IndexedDB, cache, or service-worker storage reads;
- password/passkey/2FA/recovery-code field values;
- arbitrary filesystem paths or shell commands;
- Manager tokens, Commander credentials, client private keys, or profile
  files;
- unrestricted CSS/XPath selectors.

The action vocabulary is finite. Semantic role/name locators are preferred;
stable attributes and structural relations are allowed by the versioned UI
contract. CSS fallback is fixed, internal, and disabled by default.

## Navigation and network policy

Every initial URL, navigation action, redirect result, download source, and
workflow-required origin is checked. Canonical HTTPS origins are allowlisted;
userinfo, fragments, noncanonical origin paths, `file:`, `data:`, `javascript:`,
loopback/private-network destinations, and unknown origins are denied or pause
the workflow for an operator. A site workflow cannot widen a profile/session
origin policy.

The only HTTP exception is the Browser Agent's explicit Manager URL, which must
be `http://127.0.0.1`, `http://localhost`, or `http://[::1]` with no credentials,
query, or fragment.

Signed artifact uploads have a separate, non-empty HTTPS origin allowlist.
The agent does not infer upload trust from browser navigation origins or the
Commander socket URL. It accepts only the central service's exact required
headers and rejects URL credentials, fragments, redirects, header injection,
size/hash mismatches, and expired or cross-artifact capabilities.

## Exclusive authority and manual intervention

One profile has at most one active lease. Automation, workflow, and manual
leases are mutually exclusive and are authoritative on the remote host.

Manual acquisition journals the transition before converting a safely paused
or ready automation session. It is idempotent for the same operator and cannot
steal another operator's lease. While manual authority is active, automation
actions fail. Release validates the exact operator and lease, leaves the
session paused, and does not itself resume a workflow. Resume reacquires
automation authority and takes a fresh observation before deciding another
action.

Stable intervention codes cover login, reauthentication, passkey, 2FA,
CAPTCHA, consent/warning, plan approval, unknown UI, and service
unavailability. The Browser Agent never attempts to defeat authentication or
anti-bot challenges.

## Non-idempotent actions

Every action has an `action_id`, an expected observation revision, a bounded
timeout, and postconditions. The remote journal records intent before browser
side effects and records the observed outcome afterward.

After a crash or timeout:

- a proven postcondition returns the existing completion;
- a proven non-execution may permit the same action ID to continue;
- an uncertain outcome becomes `action_outcome_unknown` and requires fresh
  observation/reconcile or manual intervention.

The system never retries a prompt submission merely because a network call or
process timed out.

## Durable workflows and events

Workflow execution belongs to an independent remote supervisor, not the
Commander connection process. Checkpoints include central/remote identity,
workflow/version, phase, absolute deadline, session/lease state, pending action,
event sequence, result, and artifact manifests.

Events are at-least-once and have a strict finite vocabulary. The remote outbox
assigns a monotonically increasing sequence and retains events until a
cumulative ACK that cannot exceed the durable emitted high-water mark. The
central store deduplicates `(remote_execution_id, sequence)`, rejects changed
duplicates, commits legal contiguous transitions, and sends ACK only after the
transaction commits. PubSub contains invalidation identifiers only, never event
payloads.

## Artifact transfer

The whole JSON-encoded inline response is limited to 131072 bytes. Larger
artifacts use the dedicated upload path or remain `remote_pending`.

An upload capability binds:

- artifact identity and exactly one central owner (`job_id` or `session_id`);
- HTTPS target and PUT method;
- exact MIME, length, and SHA-256 headers;
- a maximum 15-minute expiry (five minutes by default);
- redirect refusal and the configured central upload origin.

The central service streams into a bounded reservation and recomputes size,
SHA-256, and MIME/extension policy. It commits verified storage and DB state
before acknowledging the remote outbox. Partial or rejected uploads are cleaned
up. A post-commit ACK failure is retried durably and idempotently. Signed
targets and upload tokens are never persisted or logged; only a one-way token
digest may be stored until verification.

Generic downloads use one finite protocol-owned MIME/extension matrix:
`.bin`, `.pdf`, `.json`, `.html`, `.md`, `.txt`, `.png`, `.jpg`, and `.jpeg`.
Crossed or unknown MIME/extension pairs are rejected before storage is exposed.

## Secret handling

Checked-in TOML contains references only:

- `platform_key_env` names the remote Commander key environment variable;
- `platform_credentials_env` names the central JSON credential-map variable;
- `manager_token_env` names the Manager Bearer-token variable;
- Commander TLS fields contain credential file paths, never PEM bodies.

Use environment injection backed by a secret manager or systemd
`LoadCredential`. Enabled components fail startup if their runtime secret,
security limit, loopback/HTTPS boundary, or TLS key pair is invalid. The
Commander transport never falls back from mTLS to unauthenticated TLS or from
WSS to WS.

## Telemetry and audit

Telemetry uses a recursive scalar allowlist. Permitted identifiers include
bounded node, profile, session, job, request, action, artifact, phase, stable
failure code, duration, and retryability values. Logs and PubSub exclude:

- prompt and custom-instruction text;
- page URL query strings, titles, semantic trees, and body text;
- artifact bodies and signed upload targets;
- cookies, browser storage, passwords, tokens, signatures, certificates, and
  private keys;
- raw exceptions, transport bodies, constraint messages, and inspected
  dependency errors.

Audit records contain actor ID, operation, resource type/ID, outcome, stable
error code, and request ID. They do not contain request or response bodies.

## Security review checks

Before release, run scoped tests plus source scans that prove:

1. no forbidden public operation or OpenAPI schema is present;
2. all Browser API routes are authenticated and documented exactly once;
3. foreign actor IDs return not-found;
4. navigation and redirect targets are policy checked;
5. manual/automation authority cannot overlap;
6. changed event/artifact retries are rejected;
7. payload, secret, PEM, CDP, and signed-target canaries do not appear in
   captured logs or PubSub messages;
8. the release contains the correct central or remote Browser application, but
   not both;
9. real TLS validates hostname/CA/client identity and fails without fallback;
10. fixture tests are not reported as real CloakBrowser/Gemini E2E evidence.
