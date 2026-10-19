# GaoNote sync through an optional SSH tunnel

SSH forwarding is optional. GaoNote's sync WebSocket uses the existing admin
listener on port 4111; it does not need a separate SSH sync listener or sync
credentials. Direct connections use the same [ingress contract](ingress.md).
GaoNote does not start SSH, manage keys, accept reverse tunnels, or require an
inbound Agent Note listener.

## Forward the existing admin listener

On the client host, an operator or service manager can establish a local forward:

```sh
ssh -N -o ExitOnForwardFailure=yes -L 127.0.0.1:14111:127.0.0.1:4111 sync-host
```

Configure Agent Note to connect to:

```text
ws://127.0.0.1:14111/note-sync/websocket?vsn=2.0.0
```

The target is the ordinary admin port as seen from the SSH server. If the admin
listener uses a different address or port, update the forwarding target. For
containers, forward to the host-published admin listener reachable by the SSH
server; a container's own loopback is a different network namespace.

No `[note_sync] ssh_enabled` or `ssh_port` setup is needed. Join `note_sync:v1`
with `protocol_version`, stable canonical `node_id`, sorted nonempty `selectors`,
and positive `max_blob_bytes`, as shown in [ingress.md](ingress.md). No peer
registration, fingerprint header, client certificate, or identity query parameter
is required. There is no automatic `wss://` downgrade; choose the forwarded
`ws://` URL explicitly.

## Connection behavior

SSH protects this optional route using the host's ordinary SSH access and
forwarding policy. It does not change GaoNote's unauthenticated sync join or
turn the node UUID into a credential. The forward reaches the existing admin
listener, including its other routes.

A first join creates peer metadata automatically. Reconnecting the same node UUID
resumes its durable pending state and memberships; a new session replaces older
operations for that UUID. Both direct and forwarded connections use the same
snapshot, attachment, delivery, and read-lease engine. Administrative revocation
can interrupt an active session, but does not block a later anonymous reconnect.

## Validation

Check that the forward targets the existing admin listener, then connect the
actual Agent Note profile without sync-specific credentials. Verify the stable
node UUID, selected profile, both directions of note and attachment transfer, and
reconnect after interrupting the tunnel. Use [receiver.md](receiver.md) for
recovery behavior.

The reports in `validation*.md` retain their historical evidence, including tests
of older mTLS and dedicated loopback transports. They are not instructions for
the current shared-port endpoint or evidence that a particular deployment's SSH
forward has been qualified.
