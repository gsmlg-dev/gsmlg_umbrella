# Proxy Rules Local Direct Admin Implementation Plan

> **Execution requirement:** Use the `executing-plans` skill for implementation. Follow test-driven development: write each failing test, observe the expected failure, implement the smallest change, rerun the scoped test, then commit the completed task.

**Goal:** Add an independent Local Direct domain form and lazy source viewer to the authenticated `/proxy-rules` admin page while sharing the existing bounded, atomic local-source mutation boundary.

**Architecture:** Generalize the Proxy-only domain batch and atomic writer names, then teach `GSMLG.ProxyRules.Source.Local` to mutate either `:proxy` or `:direct` by selecting the matching snapshot and target. Keep explicit public facade functions and independent LiveView forms. Extend the existing paginated controller and virtual-list hook with `local-direct`; do not expose source bodies in LiveView state or initial HTML.

**Tech Stack:** Elixir 1.18, OTP 28, Phoenix LiveView, ExUnit, JavaScript/Bun, DuskMoon components.

**Approved specification:** `docs/superpowers/specs/2026-08-04-proxy-rules-local-direct-admin-design.md`

---

## Task 1: Generalize the local domain helpers

**Files:**

- Rename: `apps/proxy_rules/lib/gsmlg/proxy_rules/local_proxy_batch.ex` → `apps/proxy_rules/lib/gsmlg/proxy_rules/local_domain_batch.ex`
- Rename: `apps/proxy_rules/lib/gsmlg/proxy_rules/local_proxy_writer.ex` → `apps/proxy_rules/lib/gsmlg/proxy_rules/local_source_writer.ex`
- Rename: `apps/proxy_rules/test/gsmlg/proxy_rules/local_proxy_batch_test.exs` → `apps/proxy_rules/test/gsmlg/proxy_rules/local_domain_batch_test.exs`
- Rename: `apps/proxy_rules/test/gsmlg/proxy_rules/local_proxy_writer_test.exs` → `apps/proxy_rules/test/gsmlg/proxy_rules/local_source_writer_test.exs`
- Modify references in: `apps/proxy_rules/lib/gsmlg/proxy_rules/source/local.ex`
- Modify references in: `apps/proxy_rules/test/gsmlg/proxy_rules_test.exs`
- Modify references in: `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs`

### Step 1: Rename tests and modules

Rename the files and module declarations from `LocalProxyBatch` to `LocalDomainBatch` and from `LocalProxyWriter` to `LocalSourceWriter`. Update aliases and function references without changing behavior.

### Step 2: Prove the neutral helpers retain their contracts

Run:

```bash
devenv shell -- mix test \
  apps/proxy_rules/test/gsmlg/proxy_rules/local_domain_batch_test.exs \
  apps/proxy_rules/test/gsmlg/proxy_rules/local_source_writer_test.exs
```

Expected: all existing canonicalization, deduplication, size-limit, and atomic-write tests pass under the neutral module names.

### Step 3: Commit

```bash
git add apps/proxy_rules apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs
git commit -m "refactor(proxy-rules): generalize local source helpers"
```

## Task 2: Add serialized Local Direct mutation and facade support

**Files:**

- Modify: `apps/proxy_rules/test/gsmlg/proxy_rules/source/local_test.exs`
- Modify: `apps/proxy_rules/test/gsmlg/proxy_rules_test.exs`
- Modify: `apps/proxy_rules/lib/gsmlg/proxy_rules/source/local.ex`
- Modify: `apps/proxy_rules/lib/gsmlg/proxy_rules.ex`

### Step 1: Write failing Local source tests

Add tests which call the new shared boundary:

```elixir
assert {:ok, result} = Local.add_domains(server, :direct, ".direct.example\n")
assert result.added_domains == ["direct.example"]
assert File.read!(direct_path) == "existing.direct\ndirect.example\n"
assert File.read!(proxy_path) == "shared.example\n"
assert_receive {:proxy_rules_source, :local_direct, %SourceSnapshot{}}
```

Also prove:

- a domain already in Proxy may be added to Direct;
- an all-existing Direct batch is an idempotent no-op;
- invalid Direct input preserves both files;
- the wrong source selector returns a bounded error without a GenServer crash;
- Direct writer and timeout failures use the existing bounded result vocabulary.

Run the focused test and observe failure because `Local.add_domains/4` does not exist:

```bash
devenv shell -- mix test apps/proxy_rules/test/gsmlg/proxy_rules/source/local_test.exs
```

### Step 2: Generalize the GenServer call

Add a source-neutral public call while retaining the Proxy compatibility wrapper:

```elixir
def add_proxy_domains(server, text, timeout), do: add_domains(server, :proxy, text, timeout)

def add_domains(server, source, text, timeout)
    when source in [:proxy, :direct] and is_binary(text) do
  GenServer.call(server, {:add_domains, source, text}, timeout)
end
```

Handle `{:add_domains, source, text}` by reading `state.entries[source]`, preparing through `LocalDomainBatch`, writing `state.targets[source].path`, reconciling both inputs, and checking the selected reconciled entry. Return `{:error, :not_found}` for unsupported source selectors.

### Step 3: Write failing facade and pagination tests

Add assertions for:

```elixir
ProxyRules.add_local_direct_domains("*.direct.example\n")
ProxyRules.add_local_direct_domains(:not_binary)
ProxyRules.get_source_page(:local_direct, nil, line_limit: 10)
```

Retain all Proxy facade behavior and make timeout test servers accept the new shared GenServer request tuple.

Run and observe the missing facade/page failures:

```bash
devenv shell -- mix test apps/proxy_rules/test/gsmlg/proxy_rules_test.exs
```

### Step 4: Implement the facade and source paging

Add `add_local_direct_domains/1` and its test-only `/3` variant using the same safe exit mapping as Proxy. Extend the `get_source_page/3` guard and types to include `:local_direct`.

### Step 5: Verify and commit

```bash
devenv shell -- mix test \
  apps/proxy_rules/test/gsmlg/proxy_rules/source/local_test.exs \
  apps/proxy_rules/test/gsmlg/proxy_rules_test.exs
git add apps/proxy_rules
git commit -m "feat(proxy-rules): add local direct mutations"
```

## Task 3: Expose paginated Local Direct content to authenticated admins

**Files:**

- Modify: `apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/proxy_rules_source_controller_test.exs`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/controllers/proxy_rules_source_controller.ex`

### Step 1: Write the failing controller tests

Change the current Local Direct rejection test into a successful, authenticated pagination test. Seed Local Direct with at least two lines, request:

```text
/proxy-rules/sources/local-direct?limit=1
```

Assert its source identifier, first line, opaque cursor, second page, and `private, no-store`. Move the unsupported-source assertion to a value such as `unknown` and preserve unauthenticated route coverage.

Run and observe the expected 404:

```bash
devenv shell -- mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/proxy_rules_source_controller_test.exs
```

### Step 2: Add the parser mapping

```elixir
defp parse_source("local-direct"), do: {:ok, :local_direct}
```

Do not add a new router entry; the existing authenticated `:source` route remains the boundary.

### Step 3: Verify and commit

```bash
devenv shell -- mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/proxy_rules_source_controller_test.exs
git add apps/gsmlg_admin_web
git commit -m "feat(admin): expose local direct source pages"
```

## Task 4: Add the independent LiveView form and three-source virtual viewer

**Files:**

- Modify: `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/proxy_rules_live/index.ex`
- Modify: `apps/gsmlg_admin_web/assets/js/hooks/proxy_rules_source_viewer.test.js`
- Modify: `apps/gsmlg_admin_web/assets/js/hooks/proxy_rules_source_viewer.js`

### Step 1: Write failing LiveView tests

Add tests that assert:

- `#proxy-rules-add-local-direct` and its textarea/submit controls render;
- the two forms are side by side at large widths and the viewer is full width below them;
- a successful Direct submission writes only Direct, clears only Direct, retains Proxy form state, and pushes `%{source: "local-direct"}`;
- invalid Direct input retains only Direct input and shows bounded line errors;
- Direct operational failures retain Direct input and do not alter Proxy errors;
- the viewer initial HTML contains Direct metadata and URL but no source body.

Run and observe the missing UI/event failures:

```bash
devenv shell -- mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs
```

### Step 2: Implement independent form state and shared event handling

Add `local_direct_form` and `local_direct_errors` at mount. Keep explicit `add_local_proxy` and `add_local_direct` event heads, delegating to a private helper which receives facade function, form key, errors key, form name, and viewer source. Success and failure must assign only the selected form keys.

Use source-neutral error labels/messages so they accurately name the selected target without duplicating validation logic.

### Step 3: Implement the approved layout

Render Add Local Proxy and Add Local Direct as sibling cards in a two-column responsive grid. Place Source Viewer in a full-width card below them. Add `:local_direct` to `@source_defaults`, `viewer_local_direct` to loaded state, the `/sources/local-direct` data attribute, and a third selector with availability, line count, and update time.

### Step 4: Write failing hook tests

Extend the fake root with `localDirectUrl` and a Local Direct button. Add tests proving:

- selecting Local Direct fetches only `/proxy-rules/sources/local-direct` on demand;
- version-bound pagination and virtualization keep the existing DOM row limit;
- `proxy-rules:source-changed` invalidates only the named Direct cache;
- source switching never renders stale Direct rows under another selector.

Run and observe URL/selector validation failures:

```bash
devenv shell -- bun test apps/gsmlg_admin_web/assets/js/hooks/proxy_rules_source_viewer.test.js
```

### Step 5: Implement the third hook source

Read `this.el.dataset.localDirectUrl`, include `local-direct` in source validation, and route it through `sourceUrl/1`. Reuse all existing fetch, invalidation, cursor, text rendering, and virtual-row behavior.

### Step 6: Verify and commit

```bash
devenv shell -- mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs
devenv shell -- bun test apps/gsmlg_admin_web/assets/js/hooks/proxy_rules_source_viewer.test.js
git add apps/gsmlg_admin_web
git commit -m "feat(admin): add local direct controls"
```

## Task 5: Update the operational contract and run scoped verification

**Files:**

- Modify: `apps/proxy_rules/test/gsmlg/proxy_rules/operational_test.exs`
- Modify: `apps/proxy_rules/README.md`
- Modify: `docs/deploy.md`

### Step 1: Write the failing operational assertions

Replace assertions that Direct is admin-hidden/read-only with checks that documentation requires both local target directories to be writable by only the service identity and mounted read/write in containers.

Run and observe the documentation mismatch:

```bash
devenv shell -- mix test apps/proxy_rules/test/gsmlg/proxy_rules/operational_test.exs
```

### Step 2: Update documentation

Document both admin forms, all three lazy viewer sources, same-source deduplication, preserved cross-list conflicts, bare-domain storage, and Direct-before-Proxy downstream ordering. Update deployment examples so both local directories support same-directory temporary files and atomic rename.

### Step 3: Run the complete scoped gate

```bash
devenv shell -- mix format --check-formatted \
  apps/proxy_rules/lib \
  apps/proxy_rules/test \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/controllers/proxy_rules_source_controller.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/proxy_rules_live/index.ex \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/proxy_rules_source_controller_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs
devenv shell -- mix test apps/proxy_rules/test
devenv shell -- mix test \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/proxy_rules_source_controller_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs
devenv shell -- bun test apps/gsmlg_admin_web/assets/js/hooks/proxy_rules_source_viewer.test.js
git diff --check
git status --short --branch
```

Expected: all scoped tests pass; formatting and whitespace checks are clean; only intentional commits are ahead of `origin/main`.

### Step 4: Commit

```bash
git add apps/proxy_rules/README.md apps/proxy_rules/test/gsmlg/proxy_rules/operational_test.exs docs/deploy.md
git commit -m "docs(proxy-rules): document local direct management"
```

Do not push, release, or deploy unless the user asks after reviewing the completed local implementation.
