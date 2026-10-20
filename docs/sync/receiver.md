# GaoNote protocol v1 receiver

GaoNote sends and receives complete Agent Note snapshots through the dedicated
`/note-sync/websocket?vsn=2.0.0` Phoenix socket and `note_sync:v1` channel.
The receiver implements the
[v1 contract](/data/development/gsmlg-opt/agent-note/.trees/codex-note-sync/docs/sync/gaonote-protocol-v1.md).
The socket uses the existing admin listener, port 4111 by default, without
WebSocket or channel authentication. See [ingress.md](ingress.md) for direct
connection and join details, or [ssh-tunnel.md](ssh-tunnel.md) for an optional
forward to the same listener. No separate sync listener or enablement flag is
required.

## Migration and peer lifecycle

Apply the existing Repo migrations before running this version, including
`20261011000000_add_gao_note_sync` and
`20261015000000_allow_ssh_sync_peers`. The latter permits the certificate-free
peer metadata used by the current endpoint. Native writers capture sync state
between connections, so the tables must exist before users resume editing.
These migrations add sync tables and permit nullable certificate fingerprints;
they do not replace or rewrite existing notes. For a release, use the existing
`GSMLG.Release.migrate()` operation.

A client joins with exactly `protocol_version = 1`, its stable canonical lowercase
node UUID, a sorted unique nonempty `selectors` list, and a positive integer
`max_blob_bytes`. No peer preregistration, browser session, actor ID, certificate,
header, or additional credential is required. The receiver validates the join
and automatically creates or reuses the peer metadata by node UUID. A new peer's
audit actor is `note_sync:<uuid>`; existing peer audit actors are preserved.
Obsolete stored certificate fingerprints are cleared when a peer joins through
the current endpoint.

Requested selectors define the sync profile; no provisioned selector allowlist
is required. Multiple rules form an OR union. Conditions inside each rule retain
the existing typed AND semantics. A UUID identifies durable peer state, not an
authenticated client. Only the current session for that UUID may access
inventories, snapshots or ACKs; reconnect replaces the previous session and
releases its read leases while preserving memberships and pending work.

Historical notes are enumerated after join and seeded one at a time. Seeding uses
their stored update/deletion timestamps, not the time of connection. UUID is the
identity; matching titles do not merge distinct notes. Inventory absence never
deletes a note. Metadata and the complete attachment set apply atomically, and
existing incompatible catalog types/descriptions reject only the affected note.
An incoming association cannot read or overwrite an existing note outside the
peer's scope unless that note was previously shared with the peer. Inventory
fences for unknown UUIDs do not grant access to later local notes.

## Operation and recovery

Pause the Agent Note worker without clearing its selected profile to stop its
connections. Durable pending snapshots remain. Local changes for selected peers
continue to advance the durable HLC and coalesce pending work.
Changing selectors establishes a durable scope generation; interrupted inventory
resumes its reconciliation on reconnect. Detach closes the association while
retaining both notes. Ordinary content edits do not reopen it. A later label
false-to-true transition or an explicit scope change can establish a newer
association.

An operator can interrupt the current session and release its read leases while
retaining local notes and pending work:

```elixir
GSMLG.GaoNote.Sync.revoke_peer(peer_node_uuid)
```

Revocation is not a persistent access block on this unauthenticated endpoint.
The next valid join for that UUID restores its requested selector profile and
creates a new session. Selector changes also invalidate old sessions and establish
a new durable scope. Use the deployment's network or proxy policy when access
must be blocked. Keep the client's durable node UUID stable across reconnects;
changing it creates a different peer instead of resuming the previous state.
To retry cached definitive note rejections:

```elixir
GSMLG.GaoNote.Sync.retry(peer_node_uuid)
```

Use `Sync.pending/1` and `Sync.membership/2` in the console to inspect affected
UUIDs and fixed rejection reasons. Avoid logging note or attachment contents.
Storage failures and uncertain commits close the session and remain eligible after
reconnect. A validated retry checks its durable received-event receipt before
preparing or uploading attachments. An identical committed event returns its ACK
without another upload or receipt write; conflicting reuse of an event ID fails
before staging. The final write transaction still rechecks session ownership,
note authorization and the receipt after staging. Exact committed ACK descriptors
release only their own
read leases; a stale ACK cannot remove a newer pending snapshot.

Pending snapshots, memberships with transferable content and active reads pin
immutable storage objects. Cleanup shares an object lock with reference
acquisition. Sync uploads reserve durable storage metadata and a recovery job
before uploading bytes. File metadata is stored in the S3 catalog. Abandoned
staging expires after 930 seconds, covering the maximum 900-second apply budget
plus a recovery margin; cleanup preserves committed attachments and
pinned objects. Catchable rollback/validation failures
also attempt immediate staging cleanup. Ordinary channel work and stalled
transfers have ten-second deadlines. Outbound attachments use 4 MiB S3 reads
with a 30-second base deadline plus one second per MiB, rounded up (at most
542 seconds under the 512 MiB blob limit). Before sending `transfer_begin`,
GaoNote reads and verifies every attachment sequentially into private temporary
files owned by the session. The negotiated aggregate limit bounds staged bytes,
and the complete preparation uses the work budget below as an absolute deadline.
The channel keeps servicing frames and pending polls during preparation.
Once announced, attachments use local 64 KiB reads in supervised tasks; there
are no S3 reads between transfer frames. Files are removed after ACK or definitive
rejection, and the session guard removes them on failure or disconnect.

An attachment preparation error, worker exit or deadline before `transfer_begin`
is isolated to that outbound note. A supervised recovery task terminates and
awaits its reader, removes only that transfer's files and releases its exact
session-owned read lease. Durable pending state remains unchanged. The channel
continues servicing heartbeats and inbound transfers, then sends other eligible
notes after recovery. Session-local retries retain a sanitized reason and use
exponential cooldowns of 5, 10, 20 seconds, up to 300 seconds; pending polls pick
up due notes without restarting inventory. Successful ACK/rejection clears the
retry entry. Stale task results and deadlines are ignored. Recovery itself uses
the ordinary task deadline, including the bounded extension below during an
active apply. Failure to complete cleanup or release a lease still closes the
channel. Failures after announcement retain the v1 session-failure behavior;
isolating those requires an agreed transfer-abort/reset protocol.

The commit task, including assembly, attachment preparation, the database
transaction and temporary-file cleanup, uses this bounded work budget:

```text
min(900 seconds, 60 seconds + 2 seconds * ceil(total bytes / MiB)
                           + 5 seconds * attachment count)
```

Total bytes include the encoded event metadata and all declared attachment sizes.
Senders allow another 30 seconds for the commit reply in either direction.
A 10,449,995-byte attachment with small event metadata therefore has an
85-second work budget and a 115-second reply budget. Waiting clients continue
Phoenix heartbeats; unrelated frames do not extend the absolute reply deadline.
Cleanup runs off the channel process, so the channel remains responsive until
the durable ACK can be sent.

If an inventory, checkout, pending, confirmation or recovery task reaches its ordinary
deadline while an inbound apply or state query is active, it receives one bounded
extension: the longest remaining apply/query budget plus ten seconds. Later work
or a duplicate expiry cannot extend that task again. Apply, query and blob deadlines retain their
own limits. Peer-session SQL transactions have a 910-second ceiling to permit
this bounded lock wait without PostgreSQL client checkout timing out at its
15-second default. Attachment reservation and upload-lock transactions allow
up to 900 seconds so slow S3 calls retain their object locks and can commit the
recovery job. The channel still enforces the shorter task budget. Other database
operations retain their existing timeouts.

Apply phase start/finish logs and `[:gsmlg, :gao_note, :sync, :apply]` telemetry
with `:start` / `:stop` suffixes distinguish `assemble`, `validate`, `receipt`, `prepare`, `transaction`,
`cleanup` and `transfer_cleanup`. Metadata includes peer/note/event UUIDs, phase
and result; finished logs include `duration_ms`. Note text, attachment paths,
credentials and raw upstream responses are excluded. A task killed on timeout
may have a phase start without its corresponding finish.

Configure the object store to abort abandoned
multipart uploads; incomplete multipart parts are not committed storage objects.
Read leases expire after 60 seconds and renew through the active session's
pending polling. Polls skip contended peer and lease rows rather than waiting
behind an apply transaction. A busy poll still validates the committed session
and renews its available leases, then retries without closing the channel or
changing pending snapshots. Mutating operations retain their peer locks.
Cleanup reclaims expired read owners even if their peer stays
offline after a VM crash. This preserves pending and membership pins; expiry
does not record a successful ACK.

Back up PostgreSQL, including all sync tables and Styx jobs, together with the
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

Sync preserves the attachment MIME declared in the hashed snapshot, including
zero-byte files and filenames renamed across extensions. Storage independently
detects the actual content type, enforces its configured policy, and records that
detected type on the storage object. Native attachment uploads retain their MIME
equality check. NUL-containing note text cannot be stored in PostgreSQL: commit
returns `note_rejected/validation_failed` for that note, without altering its
content or closing the channel. The client retains the pending note and caches
the rejection; other notes continue, and editing the rejected note permits retry.

Sync regex selectors accept a conservative common subset: ASCII literals,
escaped regex punctuation, `^`/`$` anchors, `|` alternatives and simple ASCII
character classes. Matching remains case-insensitive. Examples include
`project~=^bear_note$` and `project~=^bear_[a-z]ote$`. Groups, wildcard dots,
repetition, Unicode/POSIX classes and class set operations are rejected at profile
selection and join. This includes `[a~~a]`, whose PCRE and Rust
results differ. Use the existing prefix/suffix operators where appropriate.
Exact selectors such as `project=bear_note`, Unicode exact values, typed AND
conditions and the OR union of rules retain their existing behavior. Legacy
unsupported scopes cannot join and are excluded from native sync capture until
replaced with supported selectors.

Generic storage delete, upload rejection, purge and folder deletion now share
the sync object lock and check current attachment references and snapshot/read
pins before changing status or removing bytes. Expired read leases are retired
under the same transaction; ordinary unreferenced objects remain purgeable.
Folder deletion refuses the entire operation if any selected object is protected.

Qualify the actual admin listener or reverse proxy with a fresh node UUID and
no browser login, preregistered peer, certificate, or identity headers. Check
invalid version/UUID/selector/limit payloads, automatic peer creation, reconnect
with the same UUID, selector changes, and superseded sessions. Forwarded addresses
and fingerprint headers must not be treated as sync identity assertions.

Run an actual Agent Note client through that ingress and verify an initial UUID
merge, both directions of labels and attachment bytes/path swaps/removal,
trash/restore/purge, offline detach/reentry, a lost ACK/reconnect, crash recovery,
and a database/object-store backup and restart. Local database, channel and
WebSocket tests are development evidence; deployment connectivity and
backup/restore acceptance require the corresponding runtime checks. Historical
`validation*.md` reports retain the ingress contracts and results from their
recorded versions rather than defining the current authentication behavior.

## Incremental state queries

The four-field v1 join request is unchanged. The channel adds
`"capabilities":["state_query_v1"]` to its successful join reply. A capable client
must send `sync_negotiate` with exactly `{"capabilities":["state_query_v1"]}` and
validate the echoed reply before sending `inventory_start {}`. Capabilities are
immutable once inventory begins. Clients that omit negotiation keep the legacy
empty inventory payloads and never receive extension events. Negotiated query
failures are session errors; they do not silently downgrade to replay.

Each direction can issue `state_query` requests on the same socket, including
while an opposite-direction request awaits its reply. A request is exactly
`{query_id,items}`, with a UUID query ID and 1–32 unique note/event ACK
descriptors. The successful reply echoes the query ID and each exact descriptor
once, in request order, as `requested`, with `association` (`missing`, `attached`, or `detached`),
`member` (the current peer-specific descriptor or null), and `head` (null or
`{version,snapshot_hash,attachments_available}`). Peer/session authorization,
note locks and cleanup locks protect consistent reads. Only an authorized attached
membership exposes its current head; detached memberships retain their frozen
control descriptor and return a null head, including after later private edits.
Queries never create
heads, memberships, ACKs, receipts, leases or pins, and never drain pending work.

Attachment availability is true only when every declared attachment has a
committed active storage reference whose size/checksum match the committed head
and whose immutable S3 object still exists with the expected size. Checks use
S3 HEAD rather than downloading bytes. Missing references/objects report false;
unverifiable storage errors report null. Empty manifests report true.

Each GaoNote inventory captures a finite set of authorized distinct UUIDs,
including retained controls and blocked members, and revalidates each captured
descriptor before acting on the comparison. Only a nonpending Snapshot with an
attached remote member, matching generation/control/content version/hash, a
matching actual head, and confirmed attachment availability skips transfer.
Attach-to-Snapshot normalization may differ in event ID and kind only for this
comparison. A received Attach that settles at the current head also becomes a
fresh nonpending Snapshot while its original receipt and exact ACK remain stable.
A newer local head retains its queued response event until exact ACK processing.
Pending events and all controls still need an exact final ACK.
A missing remote association conditionally queues a fresh Attach event ID for an
unchanged local Snapshot while preserving generation/control/version/content.
It cannot override a remote fence by inventing a generation.

Pending work takes priority over audit work, with an audit selection after at
most eight pending selections. Each direction prepares and transfers one note
at a time in metadata, attachments, commit/ACK order. Preparation failure
retains the existing per-note cleanup and retry behavior; inbound requests and
heartbeats continue while a probe or transfer awaits its peer. A negotiated
round ends with `inventory_complete {inventory_id,total_notes}`, where the UUID
and count describe that GaoNote round's distinct authorized classified notes.
The legacy completion payload remains `{}`. New durable work starts another
round; an idle session reconciles periodically. A completion message is a round
boundary, not proof that blocked or newly edited notes were delivered.
