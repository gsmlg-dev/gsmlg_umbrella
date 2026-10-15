# SSH sync receiver validation, 2026-10-15

Issue [#11](https://github.com/gsmlg-dev/gsmlg_umbrella/issues/11) was qualified on
`main`, based on `92c9eb06a9fc3c7d934e594bf9805951675424b6`, for release v5.13.7.
The operator confirmed the certificate-free SSH contract. See
[ssh-tunnel.md](ssh-tunnel.md) for configuration and provisioning.

## Executed checks

| Check | Result |
| --- | --- |
| GaoNote sync domain regressions | PASS: 97 tests, 0 failures |
| Admin sync channel/socket/real WebSocket regressions | PASS: 27 tests, 0 failures |
| Sync configuration regressions | PASS: 6 tests, 0 failures |
| Strict compilation | PASS: `mix compile --warnings-as-errors` |
| Changed Elixir file formatting | PASS: 14 files |
| Credo using repository checks restricted to changed files | PASS: 14 files, no issues |
| Migration preservation and rollback probe | PASS |
| Diff whitespace | PASS |

The combined suite passed **130 tests, 0 failures**, seed `81999`, on Elixir
1.18.5 / OTP 28.5.0.5 with task-owned PostgreSQL 16.15. The isolated Unix-socket
database was `gsmlg_internal_11_test`; no production database or object store was
used. Test logs are under `/tmp/gsmlg-internal-11-tests/`.

```sh
MIX_ENV=test mix test \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/sync \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/channels/note_sync_channel_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/channels/note_sync_socket_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/channels/note_sync_ssh_socket_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/channels/note_sync_websocket_test.exs \
  apps/gsmlg_config/test/gsmlg/config/note_sync_config_test.exs
```

Deliberate RED runs first reproduced the missing configuration and SSH peer APIs,
then the missing SSH socket and channel join path. GREEN covers actual V2 frames
without certificate headers or identity query parameters, inbound durable note
commit, outbound historical inventory and ACK, exact peer/grant checks, and
revocation/selector changes closing the transport with guard cleanup. Existing
attachment, recovery, lease, and certificate rotation regressions pass.

The migration probe applied the actual migration around a stored mTLS peer and
pending record, compared both unchanged, provisioned two SSH peers, verified that
rollback rejects their NULL fingerprints without changing rows or migration state,
then removed the probe peers and successfully rolled back and reapplied. The
fingerprint uniqueness regression also passes.

Startup still logs existing local node-start and endpoint-broadcast warnings.
Fault-injection regressions intentionally log a failed object range read and a
disconnected database client; these do not fail the suite.

## Deployment acceptance

Actual host SSH forwarding permissions, container/network namespace reachability,
the deployed Agent Note client, production sync, and backup/restore were NOT RUN
for this receiver change. The existing production deployment was unchanged.
Qualify these when enabling the listener using [ssh-tunnel.md](ssh-tunnel.md).
