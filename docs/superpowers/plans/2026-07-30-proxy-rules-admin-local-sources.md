# Proxy Rules Admin Local Sources Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add authenticated bulk Local proxy domain input and lazy virtualized GFWList/Local proxy source viewing to `/proxy-rules`.

**Architecture:** Keep Phoenix out of `proxy_rules`: pure modules validate batches, paginate immutable snapshots, and atomically replace the local file; the Local GenServer serializes mutations and the public facade is the only admin boundary. `gsmlg_admin_web` adds an authenticated paginated JSON controller, a LiveView form/card, and a dependency-free JavaScript virtual-list hook that never puts source bodies in LiveView assigns.

**Tech Stack:** Elixir 1.18, OTP 28, Phoenix 1.8, LiveView 1.2, Phoenix DuskMoon, Bun 1.3, ExUnit, native browser `fetch`, existing FileSystem/IDNA/telemetry dependencies.

---

## File Structure

### Backend: `apps/proxy_rules`

- Create `lib/gsmlg/proxy_rules/source_page.ex` — pure bounded cursor pagination for immutable `SourceSnapshot` content.
- Create `lib/gsmlg/proxy_rules/local_proxy_batch.ex` — strict textarea parsing, IDNA normalization, and submitted-domain deduplication.
- Create `lib/gsmlg/proxy_rules/local_proxy_writer.ex` — atomic same-directory temporary write, sync, close, rename, and bounded error mapping.
- Modify `lib/gsmlg/proxy_rules/source_snapshot.ex` — retain source line count with snapshots.
- Modify `lib/gsmlg/proxy_rules/source/remote.ex` — populate remote line count when accepting decoded GFWList.
- Modify `lib/gsmlg/proxy_rules/source/local.ex` — populate local line count and serialize `add_proxy_domains`.
- Modify `lib/gsmlg/proxy_rules/persistence.ex` — restore line count for cached remote snapshots.
- Modify `lib/gsmlg/proxy_rules/coordinator.ex` — expose bounded internal snapshot reads and line count in source metadata.
- Modify `lib/gsmlg/proxy_rules.ex` — expose the stable add and source-page facade functions.
- Create tests mirroring each new pure/runtime module and extend facade, Coordinator, Local, persistence, and operational tests.

### Admin: `apps/gsmlg_admin_web`

- Create `lib/gsmlg/admin_web/controllers/proxy_rules_source_controller.ex` — authenticated JSON page response with bounded HTTP status mapping.
- Modify `lib/gsmlg/admin_web/router.ex` — add the browser-session-authenticated source page route.
- Modify `lib/gsmlg/admin_web/live/proxy_rules_live/index.ex` — add form handling and the two inline cards.
- Create `assets/js/hooks/proxy_rules_source_viewer.js` — lazy fetch and fixed-row virtualized rendering.
- Create `assets/js/hooks/proxy_rules_source_viewer.test.js` — pure state/range tests under Bun.
- Modify `assets/js/hooks.js` — register the hook.
- Extend controller and LiveView tests.

### Operations and documentation

- Modify `apps/proxy_rules/README.md` — document admin additions, source viewing, and local-proxy-only write permissions.
- Modify `docs/deploy.md` — make only `proxy-list.txt` writable by the release identity.
- Modify `apps/proxy_rules/test/gsmlg/proxy_rules/operational_test.exs` — assert the documented permission split.

## Task 1: Immutable Source Metadata and Bounded Pagination

**Files:**
- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/source_page.ex`
- Create: `apps/proxy_rules/test/gsmlg/proxy_rules/source_page_test.exs`
- Modify: `apps/proxy_rules/lib/gsmlg/proxy_rules/source_snapshot.ex`
- Modify: `apps/proxy_rules/lib/gsmlg/proxy_rules/source/remote.ex`
- Modify: `apps/proxy_rules/lib/gsmlg/proxy_rules/source/local.ex`
- Modify: `apps/proxy_rules/lib/gsmlg/proxy_rules/persistence.ex`
- Modify: `apps/proxy_rules/lib/gsmlg/proxy_rules/coordinator.ex`
- Modify: `apps/proxy_rules/lib/gsmlg/proxy_rules.ex`
- Test: `apps/proxy_rules/test/gsmlg/proxy_rules_test.exs`
- Test: `apps/proxy_rules/test/gsmlg/proxy_rules/coordinator_test.exs`
- Test: `apps/proxy_rules/test/gsmlg/proxy_rules/persistence_test.exs`

- [ ] **Step 1: Write failing SourcePage tests**

Add tests that build a `%SourceSnapshot{content: "one\ntwo\nthree\n", line_count: 3}` and assert:

```elixir
assert {:ok,
        %{
          source: :remote_gfwlist,
          version: version,
          availability: :ready,
          total_lines: 3,
          start_line: 1,
          lines: ["one", "two"],
          next_cursor: cursor,
          has_more: true
        }} =
         SourcePage.page(:remote_gfwlist, snapshot, nil, line_limit: 2, byte_limit: 64)

assert {:ok,
        %{version: ^version, start_line: 3, lines: ["three"], has_more: false}} =
         SourcePage.page(:remote_gfwlist, snapshot, cursor, line_limit: 2, byte_limit: 64)
```

Cover:

```elixir
assert {:error, :invalid_cursor} =
         SourcePage.page(:remote_gfwlist, snapshot, "bad", [])

changed = %{snapshot | content_sha256: String.duplicate("b", 64)}
assert {:error, :source_changed} =
         SourcePage.page(:remote_gfwlist, changed, cursor, [])

assert {:error, :page_too_large} =
         SourcePage.page(:remote_gfwlist, %{snapshot | content: String.duplicate("x", 65)}, nil,
           line_limit: 2,
           byte_limit: 64
         )
```

Also test empty content, a final line without `\n`, CR/LF preservation as text, maximum line-limit clamping, and cursor tampering.

- [ ] **Step 2: Run SourcePage tests and verify RED**

Run:

```bash
devenv shell -- mix test apps/proxy_rules/test/gsmlg/proxy_rules/source_page_test.exs
```

Expected: compilation failure because `GSMLG.ProxyRules.SourcePage` and `SourceSnapshot.line_count` do not exist.

- [ ] **Step 3: Add line counting to SourceSnapshot and source creation**

Add the optional field and a bounded binary scanner:

```elixir
defstruct [
  :kind,
  :content,
  :content_sha256,
  :observed_at,
  line_count: 0,
  metadata: %{},
  availability: :ready
]

@spec count_lines(binary()) :: non_neg_integer()
def count_lines(""), do: 0
def count_lines(content) when is_binary(content), do: count_lines(content, 0, 0)

defp count_lines(content, offset, count) do
  case :binary.match(content, "\n", scope: {offset, byte_size(content) - offset}) do
    {position, 1} ->
      count_lines(content, position + 1, count + 1)

    :nomatch ->
      if offset < byte_size(content), do: count + 1, else: count
  end
end
```

Populate `line_count: SourceSnapshot.count_lines(content)` in:

- Remote accepted snapshot construction.
- Local ready/missing/stale snapshot construction.
- Persisted remote snapshot restoration.

Keep existing test-built snapshots compatible by retaining the `0` default.

- [ ] **Step 4: Implement pure bounded cursor pagination**

Implement `SourcePage.page/4` with defaults of 200 lines and 256 KiB, hard maxima of 500 lines and 256 KiB. Encode cursors as URL-safe Base64 of:

```text
<64-hex-version>:<byte-offset>:<one-based-next-line>
```

Validate the decoded cursor with:

```elixir
~r/\A([0-9a-f]{64}):(\d+):(\d+)\z/
```

Walk the binary with `:binary.match/2`; do not call `String.split/2` on the full source. Return:

```elixir
%{
  source: source,
  version: snapshot.content_sha256,
  availability: snapshot.availability,
  observed_at: snapshot.observed_at,
  last_success_at: Map.get(snapshot.metadata, :last_success_at) ||
    Map.get(snapshot.metadata, :fetched_at),
  total_lines: snapshot.line_count,
  start_line: start_line,
  lines: lines,
  next_cursor: cursor_or_nil,
  has_more: boolean
}
```

Return `:page_too_large` if one complete source line exceeds the byte maximum; never return a partial line.

- [ ] **Step 5: Run SourcePage tests and verify GREEN**

Run:

```bash
devenv shell -- mix test apps/proxy_rules/test/gsmlg/proxy_rules/source_page_test.exs
```

Expected: all SourcePage tests pass.

- [ ] **Step 6: Write failing Coordinator and facade tests**

Add Coordinator assertions:

```elixir
assert {:ok, %SourceSnapshot{content: decoded}} =
         Coordinator.source_snapshot(:remote_gfwlist, coordinator)

assert decoded =~ "||example.com^"
assert {:error, :not_found} =
         Coordinator.source_snapshot(:local_proxy, coordinator_without_local)
assert {:error, :not_found} =
         Coordinator.source_snapshot(:local_direct, coordinator)
```

The last assertion locks the public scope: local direct is not viewable through
the new operation. Add an explicit fallback:

```elixir
def source_snapshot(_source, _server), do: {:error, :not_found}
```

Add facade assertions:

```elixir
assert {:ok, %{source: :remote_gfwlist, lines: [_ | _]}} =
         ProxyRules.get_source_page(:remote_gfwlist, nil, line_limit: 10)

assert {:ok, %{source: :local_proxy}} =
         ProxyRules.get_source_page(:local_proxy, nil, line_limit: 10)

assert {:error, :not_found} =
         ProxyRules.get_source_page(:local_direct, nil, [])
```

Assert that a stopped Coordinator becomes `{:error, :not_available}` rather than exiting the caller.

- [ ] **Step 7: Run facade tests and verify RED**

Run:

```bash
devenv shell -- mix test \
  apps/proxy_rules/test/gsmlg/proxy_rules_test.exs \
  apps/proxy_rules/test/gsmlg/proxy_rules/coordinator_test.exs
```

Expected: failures because `source_snapshot/2` and `get_source_page/3` do not exist.

- [ ] **Step 8: Implement Coordinator snapshot access and facade paging**

Add:

```elixir
@spec source_snapshot(:remote_gfwlist | :local_proxy, GenServer.server()) ::
        {:ok, SourceSnapshot.t()} | {:error, :not_found | :not_available}
def source_snapshot(source, server \\ __MODULE__)
    when source in [:remote_gfwlist, :local_proxy] do
  safe_call(server, {:source_snapshot, source})
end
```

Handle the request by mapping `:remote_gfwlist` to `state.remote` and
`:local_proxy` to `state.local_proxy`. Reply `{:error, :not_found}` for `nil` or
`:missing` snapshots; allow `:stale` snapshots as last-known-good content.

Add `line_count` to `source_summary/2`.

In the facade, add:

```elixir
@spec get_source_page(:remote_gfwlist | :local_proxy, binary() | nil, keyword()) ::
        {:ok, map()}
        | {:error,
           :invalid_cursor
           | :source_changed
           | :page_too_large
           | :not_found
           | :not_available}
def get_source_page(source, cursor \\ nil, options \\ [])
    when source in [:remote_gfwlist, :local_proxy] and is_list(options) do
  with {:ok, snapshot} <- Coordinator.source_snapshot(source) do
    SourcePage.page(source, snapshot, cursor, options)
  end
end

def get_source_page(_source, _cursor, _options), do: {:error, :not_found}
```

The SourcePage call runs in the caller process, outside the Coordinator mailbox.

- [ ] **Step 9: Verify snapshot restoration and all scoped pagination tests**

Run:

```bash
devenv shell -- mix test \
  apps/proxy_rules/test/gsmlg/proxy_rules/source_page_test.exs \
  apps/proxy_rules/test/gsmlg/proxy_rules_test.exs \
  apps/proxy_rules/test/gsmlg/proxy_rules/coordinator_test.exs \
  apps/proxy_rules/test/gsmlg/proxy_rules/persistence_test.exs \
  apps/proxy_rules/test/gsmlg/proxy_rules/source/remote_test.exs \
  apps/proxy_rules/test/gsmlg/proxy_rules/source/local_test.exs
```

Expected: all tests pass and persisted/remote/local snapshots report correct line counts.

- [ ] **Step 10: Commit Task 1**

```bash
git add apps/proxy_rules/lib apps/proxy_rules/test
git commit -m "feat(proxy-rules): page source snapshots"
```

## Task 2: Strict Batch Validation and Deduplication

**Files:**
- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/local_proxy_batch.ex`
- Create: `apps/proxy_rules/test/gsmlg/proxy_rules/local_proxy_batch_test.exs`

- [ ] **Step 1: Write failing batch tests**

Assert the wished-for API:

```elixir
existing = "# operator note\nexisting.com\n"
input = "Baidu.com\n例子.测试\nbaidu.com\nexisting.com\n"

assert {:ok,
        %{
          content:
            "# operator note\nexisting.com\n" <>
              "baidu.com\nxn--fsqu00a.xn--0zwm56d\n",
          added_domains: ["baidu.com", "xn--fsqu00a.xn--0zwm56d"],
          added_count: 2,
          duplicate_count: 2
        }} = LocalProxyBatch.prepare(existing, input, max_bytes: 8 * 1024 * 1024)
```

Add atomic invalid-batch assertions:

```elixir
assert {:error,
        {:invalid_batch,
         [
           %{line: 2, reason: :url_not_allowed},
           %{line: 3, reason: :ip_literal}
         ]}} =
         LocalProxyBatch.prepare("", "ok.example\nhttps://bad.example\n127.0.0.1\n")
```

Cover empty input, leading-dot rejection, comments, wildcards, CIDR, invalid
IDNA, whitespace-only lines, CRLF input, all-duplicate success, submission
order, existing accepted legacy entries, and final-body `:body_too_large`.

- [ ] **Step 2: Run batch tests and verify RED**

Run:

```bash
devenv shell -- mix test apps/proxy_rules/test/gsmlg/proxy_rules/local_proxy_batch_test.exs
```

Expected: compilation failure because `LocalProxyBatch` does not exist.

- [ ] **Step 3: Implement strict parsing and result construction**

Implement:

```elixir
@spec prepare(binary(), binary(), keyword()) ::
        {:ok,
         %{
           content: binary(),
           added_domains: [binary()],
           added_count: non_neg_integer(),
           duplicate_count: non_neg_integer()
         }}
        | {:error, :empty_batch | :body_too_large | {:invalid_batch, [map()]}}
def prepare(existing, input, options)
    when is_binary(existing) and is_binary(input) and is_list(options) do
  max_bytes = Keyword.fetch!(options, :max_bytes)

  with {:ok, submitted} <- validate_lines(input),
       {:ok, result} <- append_unique(existing, submitted),
       true <- byte_size(result.content) <= max_bytes do
    {:ok, result}
  else
    false -> {:error, :body_too_large}
    {:error, _reason} = error -> error
  end
end
```

Before `Domain.normalize/1`, reject:

```elixir
String.starts_with?(value, [".", "#", "!"])
String.contains?(value, ["://", "/", "*"])
```

Map these to bounded reasons such as `:leading_dot_not_allowed`,
`:comment_not_allowed`, `:url_not_allowed`, `:path_not_allowed`,
`:wildcard_not_allowed`; preserve existing `Domain.error_reason()` atoms for
domain failures.

Build the existing canonical-domain set by ignoring blank/comment lines and
normalizing accepted legacy source lines. Preserve the exact normalized
existing source body; append only new canonical bare domains. Count every
submitted canonical domain omitted because it was earlier in the batch or
already present.

- [ ] **Step 4: Run batch tests and verify GREEN**

Run:

```bash
devenv shell -- mix test apps/proxy_rules/test/gsmlg/proxy_rules/local_proxy_batch_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Commit Task 2**

```bash
git add \
  apps/proxy_rules/lib/gsmlg/proxy_rules/local_proxy_batch.ex \
  apps/proxy_rules/test/gsmlg/proxy_rules/local_proxy_batch_test.exs
git commit -m "feat(proxy-rules): validate local proxy batches"
```

## Task 3: Atomic Local Proxy File Writer

**Files:**
- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/local_proxy_writer.ex`
- Create: `apps/proxy_rules/test/gsmlg/proxy_rules/local_proxy_writer_test.exs`

- [ ] **Step 1: Write failing atomic-writer tests**

Use `@tag :tmp_dir` and assert:

```elixir
path = Path.join(tmp_dir, "proxy-list.txt")
File.write!(path, "old.example\n")

assert :ok = LocalProxyWriter.write(path, "new.example\n")
assert File.read!(path) == "new.example\n"
assert Path.wildcard(Path.join(tmp_dir, ".proxy-list.txt.tmp-*")) == []
```

Inject operation overrides into the `@doc false write/3` test seam:

```elixir
assert {:error, :permission_denied} =
         LocalProxyWriter.write(path, "new.example\n",
           open: fn _tmp -> {:error, :eacces} end
         )

assert {:error, :write_failed} =
         LocalProxyWriter.write(path, "new.example\n",
           sync: fn _io -> {:error, :eio} end
         )

assert {:error, :rename_failed} =
         LocalProxyWriter.write(path, "new.example\n",
           rename: fn _tmp, _target -> {:error, :exdev} end
         )
```

Assert the original target survives every pre-rename failure and temporary
files are cleaned after close.

- [ ] **Step 2: Run writer tests and verify RED**

Run:

```bash
devenv shell -- mix test apps/proxy_rules/test/gsmlg/proxy_rules/local_proxy_writer_test.exs
```

Expected: compilation failure because `LocalProxyWriter` does not exist.

- [ ] **Step 3: Implement same-directory atomic replacement**

Implement the production path as:

```elixir
def write(path, content), do: write(path, content, [])

@doc false
def write(path, content, overrides) when is_binary(path) and is_binary(content) do
  temporary = temporary_path(path)
  open = Keyword.get(overrides, :open, &:file.open(&1, [:write, :binary, :raw, :exclusive]))
  write = Keyword.get(overrides, :write, &:file.write/2)
  sync = Keyword.get(overrides, :sync, &:file.sync/1)
  close = Keyword.get(overrides, :close, &:file.close/1)
  rename = Keyword.get(overrides, :rename, &File.rename/2)
  remove = Keyword.get(overrides, :remove, &File.rm/1)

  with {:ok, io} <- open.(String.to_charlist(temporary)),
       :ok <- write.(io, content),
       :ok <- sync.(io),
       :ok <- close.(io),
       :ok <- rename.(temporary, path) do
    :ok
  else
    failure ->
      _ = remove.(temporary)
      bounded_failure(failure)
  end
end
```

Ensure close runs in an `after` block when a descriptor was opened, and ensure
the successful close is not repeated. Generate the temporary name in
`Path.dirname(path)` with a positive unique integer. Map only `:eacces` and
`:eperm` to `:permission_denied`; map write/sync/close/rename failures to
bounded stage-specific atoms.

- [ ] **Step 4: Run writer tests and verify GREEN**

Run:

```bash
devenv shell -- mix test apps/proxy_rules/test/gsmlg/proxy_rules/local_proxy_writer_test.exs
```

Expected: all tests pass with no leftover temporary files.

- [ ] **Step 5: Commit Task 3**

```bash
git add \
  apps/proxy_rules/lib/gsmlg/proxy_rules/local_proxy_writer.ex \
  apps/proxy_rules/test/gsmlg/proxy_rules/local_proxy_writer_test.exs
git commit -m "feat(proxy-rules): atomically write local proxy source"
```

## Task 4: Serialized Local Mutation and Public Facade

**Files:**
- Modify: `apps/proxy_rules/lib/gsmlg/proxy_rules/source/local.ex`
- Modify: `apps/proxy_rules/lib/gsmlg/proxy_rules.ex`
- Test: `apps/proxy_rules/test/gsmlg/proxy_rules/source/local_test.exs`
- Test: `apps/proxy_rules/test/gsmlg/proxy_rules_test.exs`
- Test: `apps/proxy_rules/test/gsmlg/proxy_rules/coordinator_test.exs`

- [ ] **Step 1: Write failing Local mutation tests**

Start a Local server with a temporary source file and injected writer:

```elixir
assert {:ok,
        %{
          added_count: 2,
          duplicate_count: 1,
          added_domains: ["baidu.com", "xn--fsqu00a.xn--0zwm56d"],
          reconciliation: :ok
        }} =
         Local.add_proxy_domains(server, "Baidu.com\n例子.测试\nbaidu.com\n")

assert File.read!(proxy_path) ==
         "existing.com\nbaidu.com\nxn--fsqu00a.xn--0zwm56d\n"
```

Assert:

- A missing file is created when its parent directory exists.
- Invalid input leaves bytes unchanged.
- Writer failure leaves snapshots and bytes unchanged.
- The final body limit is enforced before writer invocation.
- Two concurrent `Task.async` calls both survive in final content.
- A successful write sends `{:proxy_rules_source, :local_proxy, snapshot}`.
- A committed write followed by failed descriptor reconciliation returns:

```elixir
{:ok, %{added_count: 1, reconciliation: {:error, :read_failed}}}
```

and does not claim publication success.

- [ ] **Step 2: Run Local tests and verify RED**

Run:

```bash
devenv shell -- mix test apps/proxy_rules/test/gsmlg/proxy_rules/source/local_test.exs
```

Expected: failures because `add_proxy_domains/2` and the writer option do not exist.

- [ ] **Step 3: Add writer injection and serialized call handling**

Add:

```elixir
@spec add_proxy_domains(GenServer.server(), binary()) ::
        {:ok, map()}
        | {:error,
           :not_available
           | :empty_batch
           | :body_too_large
           | :permission_denied
           | :write_failed
           | :rename_failed
           | {:invalid_batch, [map()]}}
def add_proxy_domains(server, text),
  do: GenServer.call(server, {:add_proxy_domains, text}, 30_000)
```

Store an injected `writer` function in Local state:

```elixir
writer: Keyword.get(options, :writer, &LocalProxyWriter.write/2)
```

Validate it with `is_function(value, 2)`.

Handle only the proxy target:

```elixir
def handle_call({:add_proxy_domains, text}, _from, state) do
  entry = state.entries.proxy
  target = state.targets.proxy

  with :ok <- writable_snapshot?(entry.snapshot),
       {:ok, result} <-
         LocalProxyBatch.prepare(entry.snapshot.content, text,
           max_bytes: @max_source_bytes
         ),
       :ok <- state.writer.(target.path, result.content) do
    reconciled = reconcile_sources(state)
    reconciliation = reconciliation_result(result.content, reconciled.entries.proxy)
    {:reply, {:ok, Map.put(result_summary(result), :reconciliation, reconciliation)}, reconciled}
  else
    {:error, reason} -> {:reply, {:error, reason}, state}
  end
end
```

Allow `:ready` and initial `:missing`; reject stale/no snapshot as
`:not_available`. Determine reconciliation success from the proxy entry's
content hash and `last_failure`, not from direct-source status.

- [ ] **Step 4: Run Local tests and verify GREEN**

Run:

```bash
devenv shell -- mix test apps/proxy_rules/test/gsmlg/proxy_rules/source/local_test.exs
```

Expected: all Local tests pass, including concurrent submissions.

- [ ] **Step 5: Write failing public-facade add tests**

Add:

```elixir
assert {:ok, %{added_count: 1, reconciliation: :ok}} =
         ProxyRules.add_local_proxy_domains("new.example\n")

assert {:error, {:invalid_batch, [%{line: 1}]}} =
         ProxyRules.add_local_proxy_domains("https://bad.example\n")
```

Stop or replace the Local service for one test and assert
`{:error, :not_available}` rather than a caller exit.

- [ ] **Step 6: Run facade tests and verify RED**

Run:

```bash
devenv shell -- mix test apps/proxy_rules/test/gsmlg/proxy_rules_test.exs
```

Expected: failure because the facade function does not exist.

- [ ] **Step 7: Implement the safe facade**

Add:

```elixir
@spec add_local_proxy_domains(binary()) :: {:ok, map()} | {:error, term()}
def add_local_proxy_domains(text) when is_binary(text) do
  Local.add_proxy_domains(Local, text)
catch
  :exit, _reason -> {:error, :not_available}
end

def add_local_proxy_domains(_text), do: {:error, {:invalid_batch, []}}
```

Alias `GSMLG.ProxyRules.Source.Local` in the facade. Keep returned reason atoms
bounded to the Local contract.

- [ ] **Step 8: Run the complete backend mutation slice**

Run:

```bash
devenv shell -- mix test \
  apps/proxy_rules/test/gsmlg/proxy_rules/local_proxy_batch_test.exs \
  apps/proxy_rules/test/gsmlg/proxy_rules/local_proxy_writer_test.exs \
  apps/proxy_rules/test/gsmlg/proxy_rules/source/local_test.exs \
  apps/proxy_rules/test/gsmlg/proxy_rules_test.exs \
  apps/proxy_rules/test/gsmlg/proxy_rules/coordinator_test.exs
```

Expected: all tests pass.

- [ ] **Step 9: Commit Task 4**

```bash
git add \
  apps/proxy_rules/lib/gsmlg/proxy_rules.ex \
  apps/proxy_rules/lib/gsmlg/proxy_rules/source/local.ex \
  apps/proxy_rules/test/gsmlg/proxy_rules_test.exs \
  apps/proxy_rules/test/gsmlg/proxy_rules/source/local_test.exs \
  apps/proxy_rules/test/gsmlg/proxy_rules/coordinator_test.exs
git commit -m "feat(proxy-rules): add local proxy domains"
```

## Task 5: Authenticated Source Page Controller

**Files:**
- Create: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/controllers/proxy_rules_source_controller.ex`
- Create: `apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/proxy_rules_source_controller_test.exs`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/router.ex`

- [ ] **Step 1: Write failing controller authentication and response tests**

Add the wished-for route tests:

```elixir
test "redirects an unauthenticated browser request", %{conn: conn} do
  conn = get(conn, ~p"/proxy-rules/sources/gfwlist")
  assert redirected_to(conn) == "/sign_in"
end

test "returns a bounded decoded GFWList page", %{authenticated_conn: conn} do
  conn = get(conn, ~p"/proxy-rules/sources/gfwlist?limit=2")

  assert %{
           "source" => "remote_gfwlist",
           "lines" => [_, _],
           "total_lines" => total,
           "has_more" => true,
           "next_cursor" => cursor
         } = json_response(conn, 200)

  assert total >= 2
  assert is_binary(cursor)
end
```

Cover `local-proxy`, an invalid source (`404`), invalid cursor (`422`),
source-changed (`409`), not found (`404`), unavailable (`503`), and
page-too-large (`422`). Assert JSON keys are bounded and contain no filesystem
path.

- [ ] **Step 2: Run controller tests and verify RED**

Run:

```bash
devenv shell -- mix test \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/proxy_rules_source_controller_test.exs
```

Expected: route helper/controller missing failure.

- [ ] **Step 3: Add the authenticated browser route**

Inside the existing scope using:

```elixir
pipe_through([:browser, :maybe_browser_auth, :ensure_authed_access])
```

add:

```elixir
get("/proxy-rules/sources/:source", ProxyRulesSourceController, :show)
```

Do not add this route to the public web app or bearer API scopes.

- [ ] **Step 4: Implement bounded parameter and status mapping**

Implement:

```elixir
def show(conn, %{"source" => source} = params) do
  with {:ok, source} <- parse_source(source),
       {:ok, limit} <- parse_limit(Map.get(params, "limit")),
       {:ok, page} <-
         ProxyRules.get_source_page(source, Map.get(params, "cursor"), line_limit: limit) do
    json(conn, page)
  else
    {:error, reason} -> render_error(conn, reason)
  end
end

defp parse_source("gfwlist"), do: {:ok, :remote_gfwlist}
defp parse_source("local-proxy"), do: {:ok, :local_proxy}
defp parse_source(_source), do: {:error, :not_found}
```

Accept limits from 1 through 500, defaulting to 200. Return only:

```elixir
%{error: %{code: Atom.to_string(reason), message: message(reason)}}
```

Use `404` for `:not_found`, `409` for `:source_changed`, `422` for invalid
cursor/limit/page size, and `503` for `:not_available`.

- [ ] **Step 5: Run controller tests and verify GREEN**

Run:

```bash
devenv shell -- mix test \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/proxy_rules_source_controller_test.exs
```

Expected: all controller tests pass.

- [ ] **Step 6: Commit Task 5**

```bash
git add \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/controllers/proxy_rules_source_controller.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/router.ex \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/proxy_rules_source_controller_test.exs
git commit -m "feat(admin): serve paged proxy rule sources"
```

## Task 6: LiveView Batch Form and Lazy Viewer Shell

**Files:**
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/proxy_rules_live/index.ex`
- Modify: `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs`

- [ ] **Step 1: Write failing render and no-eager-content tests**

Extend the existing authenticated LiveView tests:

```elixir
assert has_element?(view, "#proxy-rules-add-local-proxy")
assert has_element?(view, "form[phx-submit='add_local_proxy']")
assert has_element?(view, "textarea[name='local_proxy[domains]']")
assert has_element?(view, "#proxy-rules-source-viewer[phx-hook='ProxyRulesSourceViewer']")
assert has_element?(view, "[data-source='gfwlist'][data-loaded='false']")
assert has_element?(view, "[data-source='local-proxy'][data-loaded='false']")
refute render(view) =~ "||remote-secret.example^"
```

Assert GFWList updated time and line count render from metadata while content
does not.

- [ ] **Step 2: Write failing form behavior tests**

Point the real Local process at a temporary proxy file using the same
`:sys.replace_state/2` and `on_exit` restoration pattern already used in this
test module.

Test:

```elixir
html =
  view
  |> form("#proxy-rules-add-local-proxy", %{
    "local_proxy" => %{"domains" => "Baidu.com\nbaidu.com\n"}
  })
  |> render_submit()

assert html =~ "Added 1 domain"
assert html =~ "ignored 1 duplicate"
assert has_element?(view, "textarea[name='local_proxy[domains]']", "")
assert File.read!(proxy_path) =~ "baidu.com\n"
```

For invalid input, assert the textarea retains the exact submission and the
page renders `Line 2: URLs are not allowed`. For a committed write with failed
reconciliation, assert the success count plus a stale/publication warning.

- [ ] **Step 3: Run LiveView tests and verify RED**

Run:

```bash
devenv shell -- mix test \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs
```

Expected: missing form, event, and viewer-shell failures.

- [ ] **Step 4: Add form state and event handling**

Initialize:

```elixir
local_proxy_form: to_form(%{"domains" => ""}, as: :local_proxy),
local_proxy_errors: []
```

Handle:

```elixir
def handle_event(
      "add_local_proxy",
      %{"local_proxy" => %{"domains" => domains}},
      socket
    ) do
  case ProxyRules.add_local_proxy_domains(domains) do
    {:ok, result} ->
      socket =
        socket
        |> assign(
          local_proxy_form: to_form(%{"domains" => ""}, as: :local_proxy),
          local_proxy_errors: []
        )
        |> put_flash(:info, add_result_message(result))
        |> push_event("proxy-rules:source-changed", %{source: "local-proxy"})

      {:noreply, socket}

    {:error, {:invalid_batch, errors}} ->
      {:noreply,
       assign(socket,
         local_proxy_form: to_form(%{"domains" => domains}, as: :local_proxy),
         local_proxy_errors: errors
       )}

    {:error, reason} ->
      {:noreply,
       socket
       |> assign(local_proxy_form: to_form(%{"domains" => domains}, as: :local_proxy))
       |> put_flash(:error, add_error_message(reason))}
  end
end
```

Bound displayed invalid lines to the backend maximum; do not call
`String.to_atom/1` on params.

- [ ] **Step 5: Render the two approved inline DuskMoon cards**

Immediately below Sources, render a responsive two-column section. Use the
project's existing `dm_card`, `dm_btn`, and form/input components. The textarea
must have:

```heex
id="proxy-rules-local-proxy-domains"
name={@local_proxy_form[:domains].name}
aria-describedby="proxy-rules-local-proxy-help proxy-rules-local-proxy-errors"
```

Render errors as a semantic list with one-based line numbers.

Render the viewer root without bodies:

```heex
<div
  id="proxy-rules-source-viewer"
  phx-hook="ProxyRulesSourceViewer"
  data-page-size="200"
  data-gfwlist-url={~p"/proxy-rules/sources/gfwlist"}
  data-local-proxy-url={~p"/proxy-rules/sources/local-proxy"}
>
```

Include source buttons, metadata/status text, a "View content" button, loading
and error live regions, a fixed-height viewport, spacer, and absolutely
positioned rows container. Mark the viewer root `phx-update="ignore"` only
around the JS-owned viewport, not the source metadata or controls.

- [ ] **Step 6: Run LiveView tests and verify GREEN**

Run:

```bash
devenv shell -- mix test \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs
```

Expected: all existing and new LiveView tests pass.

- [ ] **Step 7: Commit Task 6**

```bash
git add \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/proxy_rules_live/index.ex \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs
git commit -m "feat(admin): add local proxy controls"
```

## Task 7: Dependency-Free Virtual Source List Hook

**Files:**
- Create: `apps/gsmlg_admin_web/assets/js/hooks/proxy_rules_source_viewer.js`
- Create: `apps/gsmlg_admin_web/assets/js/hooks/proxy_rules_source_viewer.test.js`
- Modify: `apps/gsmlg_admin_web/assets/js/hooks.js`

- [ ] **Step 1: Write failing pure virtual-list tests**

Using `bun:test`, assert:

```javascript
import { describe, expect, test } from "bun:test";
import {
  appendPage,
  sourcePageUrl,
  visibleRange,
} from "./proxy_rules_source_viewer.js";

test("computes a bounded visible window with overscan", () => {
  expect(visibleRange({
    scrollTop: 240,
    viewportHeight: 120,
    rowHeight: 24,
    loadedCount: 100,
    overscan: 3,
  })).toEqual({ start: 7, end: 18 });
});

test("appends one version and rejects mixed versions", () => {
  const first = appendPage(null, {
    version: "a".repeat(64),
    start_line: 1,
    lines: ["one", "two"],
    next_cursor: "cursor",
    has_more: true,
    total_lines: 3,
  });

  expect(first.lines).toEqual(["one", "two"]);
  expect(() =>
    appendPage(first, {
      version: "b".repeat(64),
      start_line: 3,
      lines: ["three"],
    })
  ).toThrow("source_changed");
});

test("builds encoded cursor URLs", () => {
  expect(sourcePageUrl("/proxy-rules/sources/gfwlist", "a+b", 200))
    .toBe("/proxy-rules/sources/gfwlist?limit=200&cursor=a%2Bb");
});
```

Also cover empty pages, reset, line-number continuity, loaded-count clamping,
and `has_more`.

- [ ] **Step 2: Run Bun tests and verify RED**

Run:

```bash
cd apps/gsmlg_admin_web
bun test assets/js/hooks/proxy_rules_source_viewer.test.js
```

Expected: module-not-found failure.

- [ ] **Step 3: Implement pure page and range helpers**

Implement and export:

```javascript
export function visibleRange({
  scrollTop,
  viewportHeight,
  rowHeight,
  loadedCount,
  overscan = 5,
}) {
  const first = Math.floor(scrollTop / rowHeight);
  const visible = Math.ceil(viewportHeight / rowHeight);
  return {
    start: Math.max(0, first - overscan),
    end: Math.min(loadedCount, first + visible + overscan),
  };
}

export function sourcePageUrl(base, cursor, limit) {
  const params = new URLSearchParams({ limit: String(limit) });
  if (cursor) params.set("cursor", cursor);
  return `${base}?${params.toString()}`;
}
```

`appendPage` must enforce one content version and contiguous one-based line
starts before returning the new immutable state.

- [ ] **Step 4: Run pure hook tests and verify GREEN**

Run:

```bash
cd apps/gsmlg_admin_web
bun test assets/js/hooks/proxy_rules_source_viewer.test.js
```

Expected: all tests pass.

- [ ] **Step 5: Implement the LiveView hook**

Export `ProxyRulesSourceViewer` with:

```javascript
mounted() {
  this.rowHeight = 24;
  this.overscan = 8;
  this.pageSize = Number(this.el.dataset.pageSize || 200);
  this.state = null;
  this.source = null;
  this.loading = false;

  this.onScroll = () => {
    this.renderWindow();
    if (this.nearLoadedEnd()) this.loadNextPage();
  };

  this.viewport().addEventListener("scroll", this.onScroll, { passive: true });
  this.el.addEventListener("click", this.onClick);
  this.handleEvent("proxy-rules:source-changed", ({ source }) => {
    if (source === this.source) this.resetAndLoad();
  });
}
```

The complete hook must:

- Switch sources without fetching until "View content".
- Fetch with `credentials: "same-origin"` and `Accept: "application/json"`.
- Keep one in-flight request.
- Reset after a `409 source_changed`.
- Update the spacer to `total_lines * rowHeight`.
- Render rows with `document.createElement` and assign source text only through
  `textContent`.
- Render line numbers separately.
- Use `requestAnimationFrame` to coalesce scroll renders.
- Fetch the next page near the end of loaded rows.
- Remove listeners and abort the active fetch in `destroyed()`.
- Show bounded messages for 404, 409, 422, 503, network, and invalid JSON.

- [ ] **Step 6: Register the hook and build assets**

In `hooks.js`:

```javascript
import ProxyRulesSourceViewer from "./hooks/proxy_rules_source_viewer";

export const hooks = {
  // existing hooks
  ProxyRulesSourceViewer,
};
```

Run:

```bash
devenv shell -- mix bun gsmlg_admin_web
```

Expected: Bun exits `0` and writes the admin bundles without unresolved imports.

- [ ] **Step 7: Commit Task 7**

```bash
git add \
  apps/gsmlg_admin_web/assets/js/hooks.js \
  apps/gsmlg_admin_web/assets/js/hooks/proxy_rules_source_viewer.js \
  apps/gsmlg_admin_web/assets/js/hooks/proxy_rules_source_viewer.test.js
git commit -m "feat(admin): virtualize proxy rule sources"
```

## Task 8: Deployment Contract, Documentation, and Final Verification

**Files:**
- Modify: `apps/proxy_rules/README.md`
- Modify: `docs/deploy.md`
- Modify: `apps/proxy_rules/test/gsmlg/proxy_rules/operational_test.exs`

- [ ] **Step 1: Write a failing operational documentation assertion**

Extend the operational test to read both docs and assert:

```elixir
assert proxy_readme =~
         "proxy-list.txt must be writable by the release service identity"

assert deploy_doc =~
         "install -o gsmlg -g gsmlg -m 0640 proxy-list.txt"

assert deploy_doc =~
         "install -o root -g gsmlg -m 0640 direct-list.txt"
```

Also assert the docs keep Local direct outside the admin write scope.

- [ ] **Step 2: Run the operational test and verify RED**

Run:

```bash
devenv shell -- mix test \
  apps/proxy_rules/test/gsmlg/proxy_rules/operational_test.exs
```

Expected: documentation permission assertions fail.

- [ ] **Step 3: Update Proxy Rules and deployment documentation**

Document:

- The textarea accepts bare domains only, one per line.
- Validation is atomic and duplicates are automatically omitted.
- Source storage remains bare-domain while renderer outputs differ.
- GFWList content is decoded, lazy, authenticated, and virtualized.
- Local direct is not viewable/editable.
- `proxy-list.txt` is service-owned/writable.
- `direct-list.txt` remains operator-owned/read-only.
- Container bind mounts must give the running container write access to only
  the configured local proxy path.

Use concrete host commands:

```bash
sudo install -d -o gsmlg -g gsmlg -m 0750 /etc/gsmlg/proxy-rules
sudo install -o gsmlg -g gsmlg -m 0640 proxy-list.txt \
  /etc/gsmlg/proxy-rules/proxy-list.txt
sudo install -o root -g gsmlg -m 0640 direct-list.txt \
  /etc/gsmlg/proxy-rules/direct-list.txt
```

- [ ] **Step 4: Run operational test and verify GREEN**

Run:

```bash
devenv shell -- mix test \
  apps/proxy_rules/test/gsmlg/proxy_rules/operational_test.exs
```

Expected: all operational assertions pass.

- [ ] **Step 5: Run all in-scope backend and admin tests**

Run:

```bash
devenv shell -- mix test apps/proxy_rules/test
devenv shell -- mix test \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/proxy_rules_source_controller_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/proxy_rules_telemetry_bridge_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/components/admin_navigation_test.exs
cd apps/gsmlg_admin_web && bun test assets/js/hooks/proxy_rules_source_viewer.test.js
```

Expected: all in-scope tests pass. If unrelated tests fail, report them and stop
without modifying unrelated code.

- [ ] **Step 6: Run scoped quality gates**

Run:

```bash
devenv shell -- mix format --check-formatted \
  apps/proxy_rules \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/controllers/proxy_rules_source_controller.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/proxy_rules_live/index.ex \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/proxy_rules_source_controller_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs
devenv shell -- mix compile --warnings-as-errors
devenv shell -- mix credo --strict apps/proxy_rules \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/controllers/proxy_rules_source_controller.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/proxy_rules_live/index.ex
devenv shell -- mix bun gsmlg_admin_web --minify
git diff --check
```

Expected: every command exits `0`.

- [ ] **Step 7: Verify the UI in a real browser**

Start the development server:

```bash
devenv shell -- mix phx.server
```

Using authenticated admin port `4111`, verify:

1. `/proxy-rules` loads without fetching `/proxy-rules/sources/gfwlist`.
2. GFWList metadata shows time/line count.
3. Clicking "View content" fetches the first page and renders decoded rules.
4. Scrolling renders bounded DOM rows and loads additional pages.
5. Switching to Local proxy resets the viewer.
6. Pasting `Baidu.com`, `baidu.com`, and a Unicode domain adds canonical unique
   bare domains.
7. Squid artifact renders `.baidu.com`; Raw renders `baidu.com`; Clash renders
   `DOMAIN-SUFFIX,baidu.com`.
8. Invalid URL input retains textarea content and does not modify the source.
9. No source line is interpreted as HTML.

Record the exact HTTP statuses and browser-console result. Expected: no
uncaught errors, source page requests return `200`, and artifact formats match.

- [ ] **Step 8: Commit Task 8**

```bash
git add \
  apps/proxy_rules/README.md \
  docs/deploy.md \
  apps/proxy_rules/test/gsmlg/proxy_rules/operational_test.exs
git commit -m "docs(proxy-rules): document admin source management"
```

- [ ] **Step 9: Final repository state**

Run:

```bash
git status --short --branch
git log --oneline --decorate -10
```

Expected: no uncommitted implementation files; the implementation branch is
ahead only by the planned commits and ready for the selected finishing
workflow.
