# GaoNote protocol v1 receiver implementation

> For agentic workers: execute the approved protocol in parallel with explicit file ownership; serialize integration and database checks. Steps use checkboxes to track completion.

**Goal:** Receive and send Agent Note full-note snapshots through a dedicated authenticated Phoenix channel, preserving UUIDs, content versions, attachments and association fences.

**Architecture:** PostgreSQL stores the local node/clock, authenticated peers, note heads, association state, latest pending snapshots, exact receipts, read leases and immutable-object pins. Existing writers capture only after all business changes have applied in their existing transaction. Network transfers stage files outside the final business transaction. A nonblocking channel sender services inbound frames while enumerating and sending blobs.

**Tech stack:** Elixir/OTP, Ecto/PostgreSQL, Phoenix V2 JSON, the existing storage backend, SHA-256, verified mTLS at a private trusted ingress.

## Scope

Approved contract: `/data/development/gsmlg-opt/agent-note/.trees/codex-note-sync/docs/sync/gaonote-protocol-v1.md` and its independent canonical hash vectors. Changes are restricted to GaoNote, its admin sync socket, sync configuration, one additive Repo migration, scoped tests and documentation. Existing anonymous sockets and browser authentication are independent. Deployment, publication and production acceptance require later operator work.

## Interfaces and ownership

- Storage/merge: `GSMLG.GaoNote.Sync` and private `Sync.Store`, `Sync.Peers`, `Sync.Engine`, `Sync.Objects`; additive migration in `apps/gsmlg/priv/repo/migrations`.
- Writer integration: existing GaoNote native/compat/bulk/catalog writers and attachment cleanup. `Sync.Snapshot.build(id)` returns `{:ok, %{snapshot: wire_snapshot, objects: public_id_to_storage_uuid}}`. `Sync.capture(id)` returns `:ok` or a tagged error inside the business transaction. Purge uses `kind: :purge` before removing the row.
- Transport: `Sync.Protocol`, `Sync.Transfer`, admin `NoteSyncSocket` and `NoteSyncChannel`, endpoint mount and disabled-by-default ingress config.
- Authentication: operator `Sync.register_peer/1` binds certificate fingerprint, node UUID, actor and allowed selectors. `Sync.join/2` returns a persisted session peer plus response. Every apply/checkout/ACK verifies the current session; replacement sessions reclaim abandoned leases.
- Transfer: `Sync.checkout(peer,id)` creates a durable read lease; `Sync.ack(peer,ack,lease)` verifies every descriptor field before removing matching pending state. `Sync.reject/3` preserves pending work and caches fixed rejection reasons; `Sync.retry/1` makes rejected notes eligible.

## Verification sequence

- [x] Run GaoNote baseline and new failing regressions against a disposable test database.
- [x] Add additive records and pin tables. Verify node identity/clock persistence, historical seed, local coalescing and transactional rollback.
- [x] Implement UUID-preserving apply with exact catalog checks, complete labels/attachments, seconds timestamps, version preservation, receipts and atomic committed ACKs.
- [x] Verify initial UUID merge, trash/restore/purge, old-generation events, detach/reentry, fences without content comparison, equal-version/different-hash errors and event-ID reuse.
- [x] Integrate all native/compat/bulk/catalog mutations and cleanup exclusion. Verify pending/read pins survive coalescing and stale ACKs cannot free newer references.
- [x] Implement canonical hashing and bounded staged transfers. Pass independent cross-language vectors and malformed blob/offset/hash/size tests.
- [x] Implement ingress trust and authorized channel sessions. Verify missing/duplicate/spoofed fingerprint rejection, exact rule authorization and obsolete sessions.
- [x] Exercise actual local WebSocket inbound commits and outbound historical inventory/ACKs, plus channel/database reconnect/replay. Verify canonical vectors and trusted-ingress header cases. These tests do not exercise a TLS ingress or client certificates.
- [x] Run only affected GaoNote, note-sync channel and sync configuration tests, strict compilation, changed-file formatting/static checks and diff whitespace checks.
- [x] Document migration, certificate/peer provisioning, private-backend ingress, backup/restart and live acceptance steps; record executed checks and outstanding production evidence.

Final implementation evidence: [validation.md](../../sync/validation.md). The scoped
suite passes **337 tests, 0 failures**. Strict compilation and formatting/Credo
checks pass. Live mTLS certificate/firewall qualification, a production Agent Note
connection and backup/restore acceptance are not run and remain outside this
implementation task. At the 2026-10-11 implementation checkpoint, no commit,
merge, push, release or deployment had been performed.

## Merge rules

Content compares lexicographic `(millis,counter,node_id)` versions; winning remote versions are preserved. Generation/control independently govern association membership. Detach freezes content and blocks ordinary body-edit reentry; a false-to-true selector transition or explicit selector reconfiguration establishes a newer generation. Fence carries no snapshot and never rewrites content. Receipts bind full event identity; ACKs bind durable read descriptors. Permanent heads and detached fences have no note-row foreign key and survive deletion.

Local note rows, pending snapshots and active read leases protect immutable objects. An advisory transaction lock per storage UUID serializes adding references with cleanup. Cleanup cannot delete referenced files; reference acquisition checks the file remains active under the same lock. Attachment preparation remains outside the final Repo transaction and cleans losing/rolled-back staging.
