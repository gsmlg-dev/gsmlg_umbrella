# Remote Browser Control Operations

This runbook covers the central `gsmlg_umbrella` release and the remote
`gsmlg_commander` release with CloakBrowser Manager v0.1.5. The Manager and CDP
remain on the remote host; only bounded Commander capability messages and
verified artifacts cross the host boundary.

The implementation targets the upstream
[CloakBrowser Manager v0.1.5](https://github.com/CloakHQ/CloakBrowser-Manager/tree/v0.1.5).
That release exposes its Manager on port 8080, supports `AUTH_TOKEN` Bearer
authentication, and documents loopback publication for Linux containers.

## Version matrix

| Surface | Supported version |
| --- | --- |
| Commander protocol | `1` |
| Commander capability | `browser.control/v1` |
| CloakBrowser Manager | `v0.1.5` |
| Gemini Deep Research | `gemini.deep_research` + `workflow_version = 1` |
| Gemini YouTube Analysis | `gemini.youtube_analysis` + `workflow_version = 1` |
| Gemini UI contract | `v1` |
| Artifact transfer | `inline`, `signed_upload`, `remote_pending` |
| REST schema | protected `/api/browser/openapi.json` |

Unknown protocol, capability, workflow, or UI-contract versions are rejected;
they are never silently coerced to a supported version.

## Stable public failure codes

Browser REST errors always use the documented JSON error envelope. Operators
and clients must branch on `code`, never on the human-readable message or an
internal exception. The stable public codes and normal responses are:

| HTTP | Class | Codes | Operator/client response |
| --- | --- | --- | --- |
| 401 | authentication | `authentication_required` | Obtain a valid Admin access Bearer token; do not retry the rejected credential. |
| 404 | resource | `not_found`, `profile_not_found`, `node_not_found` | Recheck the actor-owned identifier. Foreign and absent resources are intentionally indistinguishable. |
| 409 | lease/profile/request | `profile_busy`, `lease_conflict`, `profile_node_mismatch`, `idempotency_conflict`, `conflict` | Refresh state, choose matching/free resources, or use a new idempotency key as indicated by `human_action`. |
| 409 | session/workflow | `invalid_session_state`, `invalid_job_state`, `illegal_job_transition`, `job_terminal`, `job_not_bound`, `session_mismatch`, `job_mismatch`, `execution_mismatch`, `max_attempts_exceeded` | Refresh or reconcile durable state; review the job when its retry limit is exhausted. |
| 409 | outcome | `stale_observation`, `action_outcome_unknown`, `session_outcome_unknown`, `close_outcome_unknown` | Observe or reconcile before deciding another action. Never blindly repeat a non-idempotent action. |
| 416 | artifact | `invalid_range` | Correct the requested byte range. |
| 422 | request/action | `actor_required`, `invalid_request`, `invalid_chat_url`, `invalid_query`, `invalid_action`, `invalid_workflow_input`, `unsupported_workflow` | Correct the request against the versioned OpenAPI/workflow contract. |
| 422 | policy | `action_not_allowed`, `navigation_not_allowed`, `profile_disabled`, `node_disabled` | Choose an allowed action, origin, profile, or node; do not attempt to bypass policy. |
| 500 | internal | `operation_failed`, `browser_internal_error` | Contact the service operator with request ID and timestamp, without payload data. |
| 503 | transport/capability | `node_offline`, `capability_not_supported`, `service_unavailable`, `unknown`, `invalid_rpc_response` | Retry only when `retryable` is true; reconcile `unknown` outcomes. |
| 503 | manager/artifact | `manager_unavailable`, `artifact_not_verified`, `storage_failed` | Restore Manager/storage health or wait for verified artifact completion, then retry. |
| 504 | workflow/transport | `workflow_deadline_exceeded`, `rpc_timeout` | Review a deadline failure; reconcile an RPC timeout before retrying. |

Human-intervention events use the stable reason codes `login_required`,
`reauth_required`, `passkey_required`, `two_factor_required`,
`captcha_required`, `account_warning`, `plan_approval_required`,
`ui_contract_mismatch`, and `action_outcome_unknown`. Complete only the human
step, release the manual lease, then resume from a fresh observation.

## Build the pinned Manager image

Build the Manager from its immutable Git tag instead of an unpinned `latest`
image:

```sh
git clone --depth 1 --branch v0.1.5 \
  https://github.com/CloakHQ/CloakBrowser-Manager.git
cd CloakBrowser-Manager
podman build --tag localhost/cloakbrowser-manager:v0.1.5 .
podman image inspect localhost/cloakbrowser-manager:v0.1.5
```

Record the resulting image ID in the host deployment record. Keep
`/var/lib/cloakbrowser-manager` on persistent storage; it contains the remote
profiles and must never be copied into the central service.

## NixOS and Podman service

The essential NixOS shape is below. The `manager.env` credential contains
`AUTH_TOKEN`, and optionally `CLOAKBROWSER_LICENSE_KEY` and
`CLOAKBROWSER_RELEASE_CHANNEL=stable`. It is created by the deployment secret
store, not by Nix or Git.

```nix
{ pkgs, ... }:
{
  virtualisation.podman.enable = true;

  users.groups.gsmlg-browser = {};
  users.users.gsmlg-browser = {
    isSystemUser = true;
    group = "gsmlg-browser";
  };

  systemd.services.cloakbrowser-manager = {
    description = "CloakBrowser Manager v0.1.5";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      User = "gsmlg-browser";
      Group = "gsmlg-browser";
      StateDirectory = "cloakbrowser-manager";
      LoadCredential = [
        "manager.env:/run/secrets/cloakbrowser-manager.env"
      ];
      ExecStart = ''
        ${pkgs.podman}/bin/podman run --rm \
          --name cloakbrowser-manager \
          --publish 127.0.0.1:8080:8080 \
          --volume /var/lib/cloakbrowser-manager:/data:Z \
          --env-file=%d/manager.env \
          localhost/cloakbrowser-manager:v0.1.5
      '';
      ExecStop = "${pkgs.podman}/bin/podman stop --time 30 cloakbrowser-manager";
      Restart = "always";
      RestartSec = 5;
      TimeoutStopSec = 45;
    };
  };
}
```

Required boundaries:

- Publish `127.0.0.1:8080` only. Do not expose Manager or CDP on a LAN or public
  interface.
- Set a nonempty `AUTH_TOKEN`; use the same value only through the Browser
  Agent's `CLOAKBROWSER_MANAGER_TOKEN` environment variable.
- Persist `/data`; do not persist secrets in that volume or in container
  arguments.
- Run only one profile concurrently in v1.

Verify liveness locally on the remote host:

```sh
curl --fail --silent --show-error http://127.0.0.1:8080/api/health
podman inspect cloakbrowser-manager --format '{{.State.Status}} {{.Image}}'
```

The authenticated `/api/status` and profile checks should be performed by the
Browser Agent or a credential-aware local probe that does not place the token
in process arguments or logs.

## Configure the releases

Use the checked examples as fragments:

- [`examples/central-browser.toml`](examples/central-browser.toml)
- [`examples/remote-browser-agent.toml`](examples/remote-browser-agent.toml)

The central service needs the following runtime inputs:

| Input | Purpose |
| --- | --- |
| `GSMLG_COMMANDER_PLATFORM_CREDENTIALS_JSON` | Per-node application-authentication keys and bound Commander names |
| TLS server/reverse-proxy configuration | WSS server identity and optional client-certificate enforcement |
| Existing storage credentials | Final verified artifact storage |

The remote service needs:

| Input | Purpose |
| --- | --- |
| `GSMLG_COMMANDER_PLATFORM_KEY` | Application authentication for exactly one `credential_id` |
| `CLOAKBROWSER_MANAGER_TOKEN` | Loopback Manager Bearer authentication |
| Client certificate chain file | Commander mTLS identity |
| Client private-key file | Commander mTLS private key |
| Server CA file, when private | Commander server verification |

Set `browser_agent.security.allowed_upload_origins` to the canonical HTTPS
origin of `browser.upload_base_url` (for example,
`https://admin.example.com`). This upload trust boundary is independent from
the browser navigation allowlist and from the Commander WebSocket origin; an
enabled agent refuses an empty or noncanonical upload-origin list.

Inject environment values with a secret store or a systemd credential-backed
environment file. Mount certificate/key material with `LoadCredential`. The
TOML contains only environment-variable names and credential file paths.

Before starting the central release, run migrations:

```sh
./bin/gsmlg_umbrella eval "GSMLG.Release.migrate()"
```

The central release must contain `gsmlg_browser`; the remote release must
contain `gsmlg_browser_agent`. They intentionally do not contain each other's
runtime application.

## External E2E gates

Ordinary test runs exclude the destructive `external` tag. Run the Manager
harness on the dedicated NixOS Browser Agent host:

```sh
BROWSER_E2E_CONFIRM_REAL=yes \
BROWSER_E2E_STATE_DIR=/var/lib/gsmlg/browser-agent-e2e \
BROWSER_E2E_CLOAK_CONTAINER=cloakbrowser-manager \
BROWSER_E2E_PROFILE_ID=gemini-e2e \
BROWSER_E2E_UPLOAD_ORIGIN=https://admin.example.com \
CLOAKBROWSER_MANAGER_TOKEN='runtime-secret' \
mix test --include external \
  apps/gsmlg_browser_agent/test/external/cloak_browser_e2e_test.exs
```

Run the full-stack harness from a separate trusted test runner. It requires the
central HTTPS origin, an actor-scoped Admin access token, real node/profile
UUIDs, a second actor token for lease-contention proof, sanitized test prompts,
and a public YouTube URL:

```sh
BROWSER_E2E_CONFIRM_REAL=yes \
BROWSER_E2E_CENTRAL_URL=https://admin.example.com \
BROWSER_E2E_ADMIN_BEARER='runtime-secret' \
BROWSER_E2E_SECOND_ADMIN_BEARER='second-actor-runtime-secret' \
BROWSER_E2E_NODE_ID='node-uuid' \
BROWSER_E2E_PROFILE_ID='profile-uuid' \
BROWSER_E2E_SAFE_CLICK_NODE_ID='operator-reviewed-observation-node-id' \
BROWSER_E2E_DEEP_RESEARCH_PROMPT='sanitized test request' \
BROWSER_E2E_RECOVERY_PROMPT='long-running sanitized recovery request' \
BROWSER_E2E_INTERVENTION_PROMPT='sanitized authentication-recovery request' \
BROWSER_E2E_INTERVENTION_REASON=two_factor_required \
BROWSER_E2E_YOUTUBE_URL='https://www.youtube.com/watch?v=example' \
BROWSER_E2E_LATENCY_SAMPLES=20 \
BROWSER_E2E_FAILURE_INJECTOR=/absolute/path/to/browser-e2e-injector \
mix test --include external \
  apps/gsmlg_admin_web/test/external/browser_control_e2e_test.exs
```

Run the real Commander mTLS handshake harness from a trusted runner that has
dedicated trusted and deliberately untrusted client identities. Both identities
must trust the real server CA, but only the trusted client chain may be in the
server's client-certificate trust store:

```sh
BROWSER_E2E_CONFIRM_REAL=yes \
BROWSER_E2E_COMMANDER_WSS_URL=wss://admin.example.com/commander-socket/websocket \
BROWSER_E2E_COMMANDER_NAME=dedicated-e2e-commander \
BROWSER_E2E_COMMANDER_CREDENTIAL_ID=dedicated-e2e-credential \
BROWSER_E2E_COMMANDER_CREDENTIAL_KEY='runtime-secret' \
BROWSER_E2E_CLIENT_CERT_FILE=/run/credentials/trusted-client-chain.pem \
BROWSER_E2E_CLIENT_KEY_FILE=/run/credentials/trusted-client-key.pem \
BROWSER_E2E_UNTRUSTED_CLIENT_CERT_FILE=/run/credentials/untrusted-client-chain.pem \
BROWSER_E2E_UNTRUSTED_CLIENT_KEY_FILE=/run/credentials/untrusted-client-key.pem \
BROWSER_E2E_SERVER_CA_FILE=/run/credentials/server-ca.pem \
mix test --include external \
  apps/gsmlg_commander/test/external/commander_mtls_e2e_test.exs
```

This harness completes the real WebSocket upgrade, Commander HMAC
authentication, `commander:<name>` channel join, protocol negotiation, Browser
capability authorization, and heartbeat. It proves that the trusted client is
accepted while missing and untrusted client certificates cannot establish that
session. It does not print credential contents or raw TLS error terms. The
full-stack `certificate_rotate` phase separately proves that rotating the live
trusted identity reconnects Commander without terminating the durable workflow.

The two bearer tokens must belong to distinct Admin actors. The harness proves
that the second actor cannot acquire the first actor's active profile lease.
`BROWSER_E2E_SAFE_CLICK_NODE_ID` must identify a harmless control that appears
in the real profile's initial observation; the harness proves the public API can
click that exact observation-issued Node ID and reject a stale revision replay.
The harness also records 20–100 live samples and enforces the PRD P95 limits:
node/profile inventory under 2 seconds, Observe under 3 seconds, and structured
Action dispatch under 2 seconds.

The failure injector is an operator-owned executable called once with each
fixed argument: `complete_human_intervention`, `commander_disconnect`,
`prepare_human_intervention`, `central_restart`, `manager_restart`,
`browser_agent_restart`, `certificate_rotate`, and `scan_sensitive_logs`.
`prepare_human_intervention` must place the dedicated profile into the exact
human-only authentication state named by `BROWSER_E2E_INTERVENTION_REASON`
without exposing the credential; allowed values are `login_required`,
`reauth_required`, `passkey_required`, `two_factor_required`,
`captcha_required`, and `account_warning`. For
`complete_human_intervention`, it must use the approved SSH/WebVNC path to
complete the configured authentication step while the harness holds the manual
lease; it must not call Browser APIs or expose GSMLG credentials. Each fault
invocation must block until the requested fault has occurred and the affected
service is ready again. The Commander phase must hold the connection down for
at least 30 minutes. The certificate phase must atomically install a new valid
client chain/key and wait for the configured connection-subtree reload. The
harness then reconciles the same durable job and verifies its final artifacts.
Never place prompts, tokens, or private keys in the injector path, arguments,
output, or committed files.

For `scan_sensitive_logs`, the injector must inspect the complete central,
Commander, Browser Agent, Manager, and reverse-proxy log interval for the
configured prompt/token canaries plus raw CDP URLs, signed upload targets,
private-key paths, cookies, and browser storage values. It returns zero only
when none are present. On failure it must print only a stable count/category,
never a matching line or canary value.

Record the host identity, image digest, release SHA, timestamps, injected
phases, final job ID/status, artifact sizes/hashes, and test summary in the
deployment evidence. Fixture-only results do not satisfy this gate.

## First profile and readiness

1. Start CloakBrowser Manager and the remote Commander release.
2. From a workstation, create an SSH tunnel to the loopback Manager.
3. Open the Manager UI, create one persistent profile, and authenticate Gemini
   manually. Do not automate password, passkey, 2FA, CAPTCHA, or recovery-code
   entry.
4. Put the profile ID in `browser_agent.default_profile_id` and ensure its
   origin policy contains the required Gemini, Google Accounts, and YouTube
   origins.
5. Confirm the Admin Browser node view reports `browser.control/v1`, Manager
   `available`, and the profile `available` before dispatching a workflow.

## Manual WebVNC handoff

Acquire the session's manual lease in Admin before opening the Manager viewer:

```sh
ssh -N -L 18080:127.0.0.1:8080 browser-host.example.com
```

Then open `http://127.0.0.1:18080` and authenticate directly to the Manager.
The tunnel is operational access; GSMLG does not proxy the VNC stream or return
a Manager credential.

The safe sequence is:

1. Wait for `waiting_human`, or explicitly acquire the actor-owned session.
2. Confirm the Admin UI shows a manual lease held by the current operator.
3. Complete the login, 2FA, CAPTCHA, consent, or unknown-page action manually.
4. Release the exact manual lease in Admin.
5. Select Resume. Resume reacquires automation authority and takes a fresh
   observation before any action; it never replays a pre-handoff action.

## Certificate rotation

Validate new material without printing private-key contents:

```sh
openssl x509 -in client-chain.pem -noout -subject -issuer -dates
openssl pkey -in client-key.pem -check -noout
openssl x509 -in client-chain.pem -pubkey -noout \
  | openssl pkey -pubin -outform DER \
  | sha256sum
openssl pkey -in client-key.pem -pubout -outform DER \
  | sha256sum
```

The two public-key hashes must match. Replace credential files atomically and
retain mode `0600` on the private key. The configured reload interval restarts
only the Commander connection subtree. Remote sessions, workflow runners,
journals, event outboxes, and artifact outboxes continue running. A failed
mTLS handshake never falls back to a client without a certificate or to
`ws://`.

## Recovery

### Central restart

The Browser reconciler reloads non-terminal jobs, asks an online Commander for
the remote execution state, ingests replayed events, advances only the highest
contiguous committed sequence, and resumes pending artifact transfers. Do not
resubmit the original workflow to recover a dispatch timeout.

### Commander connection loss

The remote workflow continues. Events and results remain in the local outbox.
After application-authenticated reconnect and capability registration, the
remote execution owner is rebound before event replay and ACK processing.

### Browser Agent restart

The agent recovers its durable session journal, workflow checkpoints, pending
actions, leases, unacknowledged events, and artifact tombstones. An uncertain
non-idempotent action becomes `outcome_unknown`; it is reconciled from a fresh
observation or handed to an operator, never blindly repeated.

### Manager restart

The profile becomes unavailable and the workflow remains paused. After Manager
health returns, reattach and observe. Do not repeat a prompt submission merely
because the process restarted.

### Artifact interruption

An upload capability is single-artifact, short-lived, exact-header-bound, and
HTTPS-only. A partial upload is aborted. The remote outbox is acknowledged only
after central size, SHA-256, MIME/extension, ownership, storage commit, and DB
verification all succeed. If remote ACK fails after that commit, the central
ACK worker retries idempotently.

## Evidence to retain

For each production acceptance run, record without payloads or secrets:

- central and remote release SHAs;
- Manager v0.1.5 source SHA and local image ID;
- Commander node/credential ID and negotiated capability version;
- test job/session IDs and terminal state;
- event highest-contiguous sequence;
- artifact IDs, sizes, and SHA-256 values;
- connection-loss, central-restart, Manager-restart, manual-handoff, and
  certificate-rotation outcomes;
- start/end timestamps and stable failure codes.

Never record prompt text, page bodies, cookies, storage, credentials, raw CDP
URLs, profile paths, signed targets, upload tokens, or artifact bodies.
