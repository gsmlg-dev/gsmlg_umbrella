# GaoNote sync v1 ingress

GaoNote exposes the `note_sync:v1` Phoenix channel on the existing admin listener,
port 4111 by default:

```text
ws://10.100.10.10:4111/note-sync/websocket?vsn=2.0.0
```

The WebSocket and channel join are unauthenticated. No browser login, peer
preregistration, client certificate, fingerprint header, identity query parameter,
or additional sync port is required. Sync does not require an enablement flag.
An optional SSH forward uses this same admin listener; see
[ssh-tunnel.md](ssh-tunnel.md).

## Connection and join

Use Phoenix V2 JSON text frames. Longpoll is not mounted. After the WebSocket
upgrade, join `note_sync:v1` with exactly these four payload fields:

```json
{
  "protocol_version": 1,
  "node_id": "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa",
  "selectors": ["project=bear_note"],
  "max_blob_bytes": 536870912
}
```

For a client that writes Phoenix frames directly, the join frame is:

```json
["1", "1", "note_sync:v1", "phx_join", {"protocol_version": 1, "node_id": "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa", "selectors": ["project=bear_note"], "max_blob_bytes": 536870912}]
```

`node_id` must be the client's stable, canonical lowercase UUID, distinct from
GaoNote's own node UUID. `selectors` must be a nonempty, sorted, unique list of
supported selector strings. Multiple selectors form an OR union; conditions
inside each selector retain typed AND semantics. `max_blob_bytes` must be a
positive integer. The receiver negotiates its configured aggregate limit, capped
at 512 MiB. Invalid join payloads return `invalid_join`.

The first valid join creates durable peer metadata automatically. Later joins
with the same node UUID reuse its memberships and pending snapshots. Requested
selectors define the sync profile directly; they are not checked against a
provisioned allowlist. Each join creates a new current session and invalidates
older operations for that node. See [receiver.md](receiver.md) for recovery and
selector changes.

## Routing and configuration

The aggregate transfer limit remains configurable in the active TOML:

```toml
[note_sync]
max_blob_bytes = 536870912
```

Use `wss://` when connecting through a TLS reverse proxy. The proxy must support
WebSocket upgrade to `/note-sync/websocket` on the normal admin upstream. No
client-certificate verification or identity-header injection is required by the
receiver. Server TLS and any deployment network access rules are independent of
the sync protocol.

The sync endpoint accepts any reachable client with a valid join payload. Node
UUIDs identify durable sync state and are not credentials; client-selected rules
are filters, not authorization grants. Apply the deployment's intended access
boundary to the existing admin listener or its reverse proxy. A browser session
and forwarded source addresses do not restrict this endpoint.

## Transfer lifecycle

Transfers expire after ten seconds without progress. Temporary assembly files and
read leases are released on channel exit; durable pending snapshots survive.
Commit work has a separate size/object budget of 60 seconds plus 2 seconds per
MiB (rounded up, including event metadata) and 5 seconds per attachment, capped
at 900 seconds. The sender waits another 30 seconds for the commit reply while
maintaining heartbeats; unrelated traffic does not reset this deadline.
See [receiver.md](receiver.md) for phase timings and retry deduplication.
Definitive `validation_failed`/`catalog_conflict` rejections retain pending work
and are cached by event ID across reconnects; a new snapshot or operator retry
makes the note eligible again. Oversized notes remain pending while other notes
continue. ACKs release leases only after full durable descriptor matching.

Validate the actual listener or reverse proxy using a new node UUID and no auth
headers, then reconnect that UUID and exercise both directions of sync. The
historical `validation*.md` reports describe the versions tested at their recorded
dates; their older certificate and dedicated-port setup is not the current join
contract.
