# GaoNote sync receiver validation

The receiver fixes and actual local Rust client interoperability were requalified
on 2026-10-13; see [validation-2026-10-13.md](validation-2026-10-13.md). The results
below preserve the original 2026-10-11 checkpoint.

Validated on 2026-10-11 in `.trees/codex-gaonote-sync`, branch
`codex/gaonote-sync`, based on `a04e40a36b01ab9c33908cba78692dd2dad7d55f`.
At the 2026-10-11 validation checkpoint, the implementation was uncommitted.
The receiver is disabled by default.

## Executed checks

| Check | Result | Evidence |
| --- | --- | --- |
| Complete GaoNote app tests | PASS: 317 tests, 0 failures | `/tmp/gaonote-sync-final-integration.log` |
| Three admin note-sync test files | PASS: 18 tests, 0 failures | Same integration log |
| Sync configuration tests | PASS: 2 tests, 0 failures | Same integration log |
| Strict compilation, `MIX_ENV=test mix compile --warnings-as-errors` | PASS | `/tmp/gaonote-sync-final-compile.log` |
| Formatting of all 38 changed/new Elixir files | PASS | `/tmp/gaonote-sync-final-format-check.log` |
| Credo with repository checks restricted to those 38 files | PASS: no issues | `/tmp/gaonote-sync-final-scoped-credo.log` |
| Canonical fixture compared with the supplied protocol vectors | PASS: exact file match | `test/fixtures/sync/hash-vectors-v1.json`; protocol tests |
| Diff whitespace check | PASS | `git diff --check` |

The combined test command exited successfully with **337 tests, 0 failures**,
using ExUnit seed `397289`. Elixir 1.18.5 / OTP 28 ran against disposable database
`gaonote_sync_test_20261011` with the additive migration applied. No production
database or object store was used.

```sh
MIX_ENV=test mix test \
  apps/gsmlg_gao_note/test \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/channels/note_sync_channel_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/channels/note_sync_socket_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/channels/note_sync_websocket_test.exs \
  apps/gsmlg_config/test/gsmlg/config/note_sync_config_test.exs
```

Supply the local test database environment when repeating this command. The
recorded run used the devenv PostgreSQL Unix socket on port 5433. The scoped Credo
configuration retained the repository's configured checks while replacing its
included-file list with the exact changed/new paths.

## Behavior covered

Database tests cover durable node/HLC, historical UUID merge and LWW, replay and
event-ID conflicts, trash/restore/purge, multi-peer purge propagation, complete
label/attachment sets, path swaps/removal, catalog conflicts, and exact stored
snapshot metadata. Native, compatibility, attachment, bulk and catalog writers
capture snapshots in their business transaction. Clock overflow, validation
failures and storage-read failures roll back business state.

Membership tests cover detach/reentry, stale generations, fences, persisted scope
reconciliation across reconnect, rejected-event retry, session replacement and
revocation. Incoming UUID collisions cannot disclose or overwrite an unshared
out-of-scope note. Unknown fences and ignored closure events do not grant access.
Rotating a fingerprint invalidates cached socket authorization.

Storage tests cover immutable object metadata and bounded legacy reads, latest
snapshot coalescing, pending and active-read pins, stale ACK rejection, expired
lease cleanup without reconnect, and active-session lease renewal. Killed upload
and finalized-but-uncommitted staging leave durable cleanup reservations/jobs;
recovery preserves committed attachments and pinned objects.

Protocol tests pass the independent canonical SHA-256 vectors and reject malformed
frames, hashes, offsets, sizes and manifests. Channel tests exercise blocked work,
responsive duplex traffic, early ACK rejection and ACK-before-commit-reply support.
Actual local TCP/WebSocket tests exercise V2 join/heartbeat, an inbound committed
note, an outbound historical inventory with exact wire bytes and a full ACK,
and missing/duplicate/unregistered trusted-ingress identity headers.

Focused deliberate failing runs reproduced metadata normalization, storage policy
classification, private-UUID access, unknown-fence authorization, abandoned lease
pins and cached certificate authorization before their respective fixes. Their
regressions pass in the final combined suite. The existing attachment read-failure
test now supplies legacy metadata so it still exercises the bounded fallback;
all original rollback assertions remain.

Test startup retains existing unrelated Bun/React/remark dependency errors and
node-start warnings. An existing unused default-argument warning remains in
`note_changeset_test.exs`. Fault-injection tests intentionally log failed object
reads/deletes and a killed database connection. These messages did not fail the
scoped suite; unrelated frontend/runtime qualification was not attempted.

## Outstanding operator acceptance

| Qualification | Status |
| --- | --- |
| Installed Caddy configuration validation | NOT RUN: Caddy unavailable locally |
| Real client certificates and backend firewall isolation | NOT RUN |
| Actual Agent Note client through the deployed ingress | NOT RUN |
| Production two-way attachment/lifecycle and offline reentry scenarios | NOT RUN |
| Full database/object-store backup, restore and restart | NOT RUN |
| Commit, merge, push, release and deployment | NOT RUN at the 2026-10-11 validation checkpoint |

Follow [receiver.md](receiver.md) and [ingress.md](ingress.md) before enabling the
receiver. Preserve the durable node, clock, membership fences, receipts, pending
snapshots and object store as a coherent backup. Object-store multipart abort
lifecycle policy is still required for abandoned incomplete multipart uploads.
