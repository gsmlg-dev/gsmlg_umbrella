# GaoNote sync through an SSH tunnel

The dedicated SSH endpoint accepts the same Phoenix V2 `note_sync:v1` protocol
as the [mTLS ingress](ingress.md). Agent Note opens one duplex WebSocket through
a host-managed SSH tunnel. GaoNote does not start SSH, manage keys, accept reverse
tunnels, or require an inbound Agent Note listener.

## Configuration and provisioning

Apply migration `20261015000000_allow_ssh_sync_peers` with
`GSMLG.Release.migrate()`. It permits explicitly provisioned SSH peers to have no
certificate fingerprint; existing mTLS peer identities and durable sync state
remain intact. Rollback refuses to restore NOT NULL while SSH peers remain.

```toml
[note_sync]
enabled = false
ssh_enabled = true
ssh_port = 4114
max_blob_bytes = 536870912
```

`enabled` continues to control the mTLS ingress, independently of `ssh_enabled`.
Both default to false. The SSH listener binds only `127.0.0.1`; its port defaults
to 4114 and must be between 1 and 65535. Restart the service after changing
listener settings. With SSH disabled, the supervised endpoint opens no listener.
Only `/note-sync/websocket` is exposed; admin pages and longpoll return 404.

Provision the client's stable node UUID and grants from a trusted release console:

```elixir
GSMLG.GaoNote.Sync.register_ssh_peer(%{
  node_id: "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa",
  actor_id: "<provisioned GaoNote actor>",
  allowed_selectors: ["project=bear_note"]
})
```

The SSH registration API rejects certificate fingerprints. `register_peer/1`
still requires a valid fingerprint and provisions an mTLS-only peer. Each entry
can join only its matching transport. To change a peer's transport, revoke it
first, then use a trusted operator update to restore grants and set the fingerprint
to nil for SSH or to the verified certificate fingerprint for mTLS. Retain its UUID
and durable state.

On the client host, an operator or service manager can establish a local forward:

```sh
ssh -N -o ExitOnForwardFailure=yes -L 127.0.0.1:14114:127.0.0.1:4114 sync-host
```

Configure Agent Note to connect to:

```text
ws://127.0.0.1:14114/note-sync/websocket?vsn=2.0.0
```

Use the existing join payload with `protocol_version`, `node_id`, `selectors`, and
`max_blob_bytes`. No identity query parameters, fingerprint headers, client
certificates, or additional sync credentials are required. There is no automatic
`wss://` downgrade; select the SSH endpoint explicitly.

## Authorization boundary

SSH access and server loopback isolation are the transport's trust boundary.
Local processes and users allowed to forward this port can select any provisioned
SSH peer UUID. A UUID selects an identity; it is not a secret. Restrict SSH access
and forwarding permissions to trusted operators/clients. The target loopback port
must be reachable from the SSH daemon's network namespace. For containers, arrange
that private network boundary explicitly; publishing a container port does not
make its internal loopback listener reachable from the host.

GaoNote checks the actual TCP peer and ignores forwarded addresses, certificate
headers, and query parameters on this endpoint. The channel validates the canonical
node UUID, requires an SSH peer, and applies its registered actor and selector
grants. The ordinary admin endpoint still requires the verified mTLS proxy and
certificate identity, even when SSH sync is enabled.

Both transports share the existing snapshot, attachment, durable delivery, and
read-lease engine. Only the current authorized session may operate. The SSH channel
subscribes to peer revocations before the join transaction so a concurrent revoke
cannot be missed. Revocation and selector changes close established WebSockets;
session cleanup releases temporary assembly files and read leases while preserving
pending snapshots. Use the [receiver operations](receiver.md) for recovery and
credential/grant changes.

## Validation

Scoped regressions cover separate configuration, fixed loopback binding, explicit
peer provisioning, transport isolation, real certificate-free V2 WebSocket join,
duplex note transfer, revocation/selector disconnects, and existing mTLS behavior.
Domain and channel tests retain attachment, delivery, lease, and stale-session
coverage. See [validation-2026-10-15.md](validation-2026-10-15.md) for executed checks.

Before enabling a deployment, validate its SSH forwarding permissions and network
namespace and connect the actual Agent Note profile through the managed tunnel.
Local receiver tests do not qualify production SSH access or client configuration.
