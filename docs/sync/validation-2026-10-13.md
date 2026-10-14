# GaoNote sync receiver fixes: local qualification, 2026-10-13

The five issues identified by the Agent Note interoperability review are fixed
in `.trees/codex-gaonote-sync-fixes`, branch `codex/gaonote-sync-fixes`, based on
`2f276b2173eb0d276080e5af0d5a453aea56acc1`. Changes are uncommitted. GaoNote `main`
remains clean at that base. The actual Rust client was built from the clean Agent
Note `codex/note-sync` worktree at `91f96fc2c63f675feed06926446c5f7d9b90d51a`.

## Resulting behavior

- Generic storage delete, upload rejection, purge and folder deletion acquire the
  existing object advisory lock, re-read the row, and check attachment references
  and sync pins before changing status or deleting bytes. UUID lock keys are
  normalized. Expired read leases can be retired; a live lease or pending snapshot
  still protects the object. Folder deletion is atomic and ordinary unreferenced
  cleanup remains supported, including deployments without GaoNote tables. Storage
  does not introduce a reverse application dependency on GaoNote.
- Sync keeps the declared, hashed attachment MIME in attachment metadata, while
  storage detects the actual content type and enforces the existing size/type
  policy. Empty objects and renamed extensions preserve their wire metadata.
  Native uploads retain their MIME equality check. Successful empty S3 response
  bodies are recognized for both ordinary and range reads.
- NUL-containing business text retains its original wire bytes and hash, then
  receives a definitive `note_rejected/validation_failed` at commit, before
  staging or database writes. Other notes continue on the same channel. Invalid
  envelopes, hashes, paths and transfers remain protocol errors.
- Regex selectors are restricted before registration, selection and join to
  ASCII literals, escaped regex punctuation, anchors, alternatives and simple
  ASCII classes. Groups, dots, repetition, Unicode/POSIX escapes and class set
  operations are rejected. Exact selectors, typed AND conditions and OR rules
  remain supported. See [receiver.md](receiver.md) for examples and legacy scopes.
- Protocol and transfer tests share a compiled `test/support` fixture. Transfer
  tests no longer rely on another test module being loaded first.

An existing native inactive-object test now injects the legacy database state
directly: the public storage delete operation correctly refuses referenced files.
Its assertions about failed attachment deletion and preserved note state remain.
The old sync test requiring all declared MIME to equal detected MIME was updated
to verify preservation of both distinct metadata fields; a policy regression
still rejects disallowed actual content disguised by a declared MIME.

## Executed checks

Evidence directory: `/tmp/gaonote-sync-fixes-20261013-yVhCqP`.
Elixir 1.18.5 / OTP 28 ran against isolated PostgreSQL databases on a private Unix
socket, with the additive sync migration applied. Test endpoints were disabled
in a disposable TOML copy; the transport tests started their own local listeners.

| Check | Result | Evidence under the directory above |
| --- | --- | --- |
| Complete GaoNote app tests | PASS: 337 tests, 0 failures | `scoped-tests-final.log` |
| Storage, storage-file and detected-content policy tests | PASS: 83 tests, 0 failures | Same log |
| Three admin note-sync transport files | PASS: 19 tests, 0 failures | Same log |
| Sync configuration tests | PASS: 2 tests, 0 failures | Same log |
| Transfer file in isolation | PASS: 4 tests, 0 failures | `fixture-green.log` |
| Strict test-environment compilation | PASS, exit 0 | `compile-test.log` |
| Scoped Credo | PASS: 16 changed/new Elixir files, no issues | `credo-final.log` |
| Formatting | PASS: 15 changed/new files; existing native test baseline recorded below | `format-scoped.log`, `format-baseline-comparison.log` |
| Actual Rust RegexBuilder against shared vectors | PASS: 17 patterns, 81 expected cases | `selector-vectors-rust.log` |
| PCRE/Rust ASCII casefold comparison | PASS: all 1,112,064 Unicode scalar values; identical 54 matching codepoints | `selector-casefold-parity.log` |
| Actual Rust client build | PASS, locked dependencies | `rust-build.log` |

The final combined suite exited 0 with **441 tests, 0 failures**, ExUnit seed
`20464`:

```sh
MIX_ENV=test mix test \
  apps/gsmlg_gao_note/test \
  apps/gsmlg_storage/test/gsmlg/storage_test.exs \
  apps/gsmlg_storage/test/gsmlg/storage/storage_file_test.exs \
  apps/gsmlg_storage/test/gsmlg/storage/content_type_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/channels/note_sync_channel_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/channels/note_sync_socket_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/channels/note_sync_websocket_test.exs \
  apps/gsmlg_config/test/gsmlg/config/note_sync_config_test.exs
```

Supply the disposable database/runtime environment when repeating this command.
No unrelated umbrella tests were run. Deliberate failing runs reproduced the
original four transfer fixture failures, two MIME rejections, unsupported regex
authorization, NUL session closure, protected-object deletion and uppercase UUID
lock divergence before their fixes.

Full-file formatting of `test/gsmlg/gao_note_test.exs` fails identically at the base
commit. The new fixture setup is formatted, and comparison of formatted base and
current source confirms that it adds no formatting drift. Existing unrelated
formatting was preserved. Test startup also retains existing Bun/remark and node
startup messages and the unused-default-argument warning in
`note_changeset_test.exs`; fault-injection tests log intentional storage/database
errors. These did not fail the scoped suite. An initial cold dev dependency build
was interrupted; the recorded strict compile is the completed test-environment
check.

## Actual local client interoperability

`interop-run1/interop-results.json` and `interop-run1/driver.log` record seven
passing checks using the actual Rust server and GaoNote receiver, temporary
certificate-required TLS ingress, and local object/embedding HTTP services:

1. Initial UUID merge in both directions, full large note content, native
   attachment ID `event`, exact 150,000/180,000 byte attachments, and ACK retirement.
2. Valid client certificate connectivity and missing-certificate rejection at
   the local TLS ingress.
3. GaoNote edit, trash, restore and permanent purge reaching the Rust client.
4. A zero-byte `application/octet-stream` attachment reaching GaoNote and returning
   to Rust after a native edit with the same MIME and exact empty bytes.
5. A Rust attachment renamed from `.txt` to `.md`, preserving `text/plain`, then
   returning from GaoNote with exact metadata and bytes.
6. A normal Turso save containing NUL receiving a cached, identified
   `validation_failed` rejection, while another note synchronizes with the
   receiver's Phoenix session UUID unchanged.
7. Editing the rejected note to valid content clearing the cached rejection,
   accepting the note, and draining all pending ACKs.

## Acceptance boundary

This qualifies the fixes locally. No production database, object store or
`admin.gsmlg.org` connection was used. Production Caddy configuration, deployed
certificate negatives and backend isolation, production offline/crash scenarios,
backup/restore, and deployment acceptance remain unverified. No commit, merge,
push, release or deployment was performed.
