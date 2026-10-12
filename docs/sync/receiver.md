# GaoNote protocol v1 receiver

GaoNote sends and receives complete Agent Note snapshots through the dedicated
`/note-sync/websocket?vsn=2.0.0` Phoenix socket and `note_sync:v1` channel.
The receiver implements the
[v1 contract](/data/development/gsmlg-opt/agent-note/.trees/codex-note-sync/docs/sync/gaonote-protocol-v1.md).
Configure the verified certificate ingress as described in [ingress.md](ingress.md).
The receiver is disabled by default.

## Migration and provisioning

Apply the additive `20261011000000_add_gao_note_sync` Repo migration before running
this version. Native writers capture sync state even while transport is disabled,
so the tables must exist before users resume editing. The migration adds peer,
record and object-pin tables; it does not replace or rewrite existing notes.
For a release, use the existing `GSMLG.Release.migrate()` operation.

Provision a peer from a trusted release console. Obtain the client node UUID from
its selected Agent Note profile; obtain the lowercase SHA-256 fingerprint from
the actual client certificate, not from a submitted HTTP header.

```elixir
GSMLG.GaoNote.Sync.register_peer(%{
  node_id: "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa",
  certificate_fingerprint: "<64 lowercase hexadecimal characters>",
  actor_id: "<provisioned GaoNote actor>",
  allowed_selectors: ["project=bear_note"]
})
```

The certificate, node, actor and allowed rules form one authorization boundary.
Joining activates an exact sorted, unique, nonempty subset of those rules.
Multiple rules form an OR union. Conditions inside each rule retain the existing
typed AND semantics. Client-supplied actor IDs and browser authentication are not
used. Only one current session per peer may access inventories, snapshots or ACKs.

Historical notes are enumerated after join and seeded one at a time. Seeding uses
their stored update/deletion timestamps, not the time of connection. UUID is the
identity; matching titles do not merge distinct notes. Inventory absence never
deletes a note. Metadata and the complete attachment set apply atomically, and
existing incompatible catalog types/descriptions reject only the affected note.
An incoming association cannot read or overwrite an existing note outside the
peer's scope unless that note was previously shared with the peer. Inventory
fences for unknown UUIDs do not grant access to later local notes.

## Operation and recovery

Pause the Agent Note worker without clearing its selected profile, or disable
GaoNote's sync transport. Durable pending snapshots remain. Local changes for
selected peers continue to advance the durable HLC and coalesce pending work.
Changing selectors establishes a durable scope generation; interrupted inventory
resumes its reconciliation on reconnect. Detach closes the association while
retaining both notes. Ordinary content edits do not reopen it. A later label
false-to-true transition or an explicit scope change can establish a newer
association.

Revocation removes the peer's grants, invalidates its session, disconnects its
socket and releases its read leases, while retaining local notes and pending work:

```elixir
GSMLG.GaoNote.Sync.revoke_peer(peer_node_uuid)
```

Before rotating credentials or updating grants, call `Sync.revoke_peer/1` to
invalidate and disconnect existing sockets. Then use a trusted operator update to
restore the peer's grants and set the replacement certificate fingerprint, followed
by client reconnect. Cached old certificate identities cannot join or use an existing
session after the fingerprint changes. Changing a registered client node
UUID creates a different peer; do not replace the durable local node identity.
To retry cached definitive note rejections:

```elixir
GSMLG.GaoNote.Sync.retry(peer_node_uuid)
```

Use `Sync.pending/1` and `Sync.membership/2` in the console to inspect affected
UUIDs and fixed rejection reasons. Avoid logging note contents or certificate
private keys. Storage failures and uncertain commits close the session and remain
eligible after reconnect. Exact committed ACK descriptors release only their own
read leases; a stale ACK cannot remove a newer pending snapshot.

Pending snapshots, memberships with transferable content and active reads pin
immutable storage objects. Cleanup shares an object lock with reference
acquisition. Sync uploads reserve a durable storage row and recovery job before
uploading bytes. Abandoned staging expires after 60 seconds; cleanup preserves
committed attachments and pinned objects. Catchable rollback/validation failures
also attempt immediate staging cleanup. The channel uses ten-second work and
stalled-transfer deadlines. Configure the object store to abort abandoned
multipart uploads; incomplete multipart parts are not committed storage objects.
Read leases expire after 60 seconds and renew through the active session's
pending polling. Cleanup reclaims expired read owners even if their peer stays
offline after a VM crash. This preserves pending and membership pins; expiry
does not record a successful ACK.

Back up PostgreSQL, including all sync tables and Oban jobs, together with the
object store. Preserve the node/clock, peers, memberships, receipts, pending
snapshots and pins. Restoring only note rows loses replay and deletion fences.
After restart, reconnect creates a fresh session and reclaims abandoned read
leases; unconfirmed pending events replay. Restore a database and its objects as
a coherent pair, with editing and sync paused during restore.

## Current limits and acceptance

The negotiated aggregate limit covers event JSON plus all attachments, up to
512 MiB. Oversized current notes remain pending and editable. Legacy attachments
without valid size/SHA-256 metadata require bounded object reads before seeding;
a legacy file over 512 MiB must be migrated, replaced or removed first.
Native `date-time` labels use wire `datetime`. Native `year`, `year-month` and
`year-season` have no v1 wire equivalent; notes containing them remain pending
until their labels are changed or the protocol is extended. No lossy conversion
is applied. The existing native storage size and MIME limits still apply.

Before enabling a deployment, qualify the actual ingress with registered,
unregistered, revoked and missing certificates; spoofed/duplicate headers;
untrusted backend addresses; and unauthorized node/rule joins. Validate the Caddy
configuration and fingerprint format on the installed version, and verify that
the backend cannot be reached directly.

Run an actual Agent Note client through that ingress and verify an initial UUID
merge, both directions of labels and attachment bytes/path swaps/removal,
trash/restore/purge, offline detach/reentry, a lost ACK/reconnect, crash recovery,
and a database/object-store backup and restart. Local database, channel and
WebSocket tests are development evidence. Deployed mTLS, production connectivity
and backup/restore acceptance remain operator work.
