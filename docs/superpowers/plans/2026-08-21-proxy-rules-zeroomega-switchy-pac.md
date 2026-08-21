# Proxy Rules ZeroOmega Switchy and PAC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add deterministic SwitchyOmega Conditions and parameterized PAC exports backed by the existing atomic Proxy Rules snapshot.

**Architecture:** Pure ZeroOmega policy, normalization, validation, and rendering modules live in `proxy_rules`. The compiler embeds one validated operational policy in the existing immutable Snapshot; a Phoenix controller reads that snapshot once, validates query options, renders exact bytes, and applies content-derived HTTP validators. No new process or database is introduced.

**Tech Stack:** Elixir 1.18, OTP 28, Phoenix 1.8, Plug, ExUnit, existing `GSMLG.ProxyRules.Store` ETS/persistence pipeline.

---

## File Map

Create these focused core files:

- `apps/proxy_rules/lib/gsmlg/proxy_rules/zero_omega/policy.ex` — immutable canonical policy struct.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/zero_omega/rule.ex` — canonical rule struct and condition/action types.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/zero_omega/diagnostic.ex` — bounded structured diagnostics.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/zero_omega/normalizer.ex` — pure normalization, validation, stable sorting, and deduplication.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/zero_omega/switchy.ex` — pure Switchy binary/result renderer.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/zero_omega/pac.ex` — strict proxy option validation and pure domain-suffix PAC renderer.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/zero_omega/rendered_rule_list.ex` — exact rendered bytes and metadata.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/zero_omega/export.ex` — format dispatch and rendered-result construction.
- `apps/gsmlg_web/lib/gsmlg/web/controllers/zero_omega_rules_controller.ex` — GET/HEAD, query parsing, ETag, and bounded errors.

Create tests and fixtures alongside those boundaries:

- `apps/proxy_rules/test/gsmlg/proxy_rules/zero_omega/normalizer_test.exs`
- `apps/proxy_rules/test/gsmlg/proxy_rules/zero_omega/switchy_test.exs`
- `apps/proxy_rules/test/gsmlg/proxy_rules/zero_omega/pac_test.exs`
- `apps/proxy_rules/test/gsmlg/proxy_rules/zero_omega/export_test.exs`
- `apps/proxy_rules/test/fixtures/zero_omega/switchy_binary.txt`
- `apps/proxy_rules/test/fixtures/zero_omega/switchy_result.txt`
- `apps/proxy_rules/test/fixtures/zero_omega/proxy.pac`
- `apps/gsmlg_web/test/gsmlg_web/controllers/zero_omega_rules_controller_test.exs`

Modify existing compiler/publication files only where required:

- `apps/proxy_rules/lib/gsmlg/proxy_rules/compiler.ex`
- `apps/proxy_rules/lib/gsmlg/proxy_rules/snapshot.ex`
- `apps/proxy_rules/lib/gsmlg/proxy_rules/persistence.ex`
- `apps/proxy_rules/lib/gsmlg/proxy_rules.ex`
- `apps/proxy_rules/test/gsmlg/proxy_rules/compiler_test.exs`
- `apps/proxy_rules/test/gsmlg/proxy_rules/persistence_test.exs`
- `apps/proxy_rules/test/gsmlg/proxy_rules/publication_concurrency_test.exs`
- `apps/gsmlg_web/lib/gsmlg/web/router.ex`
- `apps/proxy_rules/README.md`

## Task 1: Canonical Policy, Diagnostics, and Normalization

**Files:**
- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/zero_omega/policy.ex`
- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/zero_omega/rule.ex`
- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/zero_omega/diagnostic.ex`
- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/zero_omega/normalizer.ex`
- Create: `apps/proxy_rules/test/gsmlg/proxy_rules/zero_omega/normalizer_test.exs`

- [ ] **Step 1: Write failing public-behavior tests**

Define test helpers that construct `%Policy{revision: "rev-1", default_action: :default, rules: rules}` and cover:

```elixir
test "normalizes enabled rules in stable priority order and removes duplicates" do
  policy = policy([
    rule("later", 20, {:domain_suffix, " Example.COM. "}, :match, 0),
    rule("disabled", 1, {:domain_suffix, "disabled.test"}, :default, 1, enabled: false),
    rule("first", 10, {:domain_suffix, "bücher.example"}, :default, 2),
    rule("same-priority", 10, {:domain_suffix, "alpha.example"}, :default, 3),
    rule("duplicate", 20, {:domain_suffix, "example.com"}, :match, 4)
  ])

  assert {:ok, %Policy{rules: normalized}} = Normalizer.normalize_policy(policy)

  assert [
    %Rule{id: "first", condition: {:domain_suffix, "xn--bcher-kva.example"}},
    %Rule{id: "same-priority", condition: {:domain_suffix, "alpha.example"}},
    %Rule{id: "later", condition: {:domain_suffix, "example.com"}, action: :match}
  ] = normalized
end

test "returns structured diagnostics for injection and invalid values" do
  policy = policy([
    rule("bad-note", 1, {:keyword, "ok"}, :default, 0, note: "bad\r\nnote"),
    rule("bad-domain", 2, {:domain_suffix, "not a host"}, :default, 1),
    rule("bad-regex", 3, {:url_regex, "("}, :default, 2),
    rule("bad-cidr", 4, {:cidr, "10.0.0.0/99"}, :default, 3)
  ])

  assert {:error, diagnostics} = Normalizer.normalize_policy(policy)
  assert Enum.map(diagnostics, & &1.code) ==
           [:line_injection, :invalid_domain, :invalid_regex, :invalid_cidr]
end
```

Also test URL parsing, exact-host IDNA, glob trimming, invalid action/profile names, missing default action, and deterministic repeated normalization.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
devenv shell -- mix test apps/proxy_rules/test/gsmlg/proxy_rules/zero_omega/normalizer_test.exs
```

Expected: compilation fails because the ZeroOmega modules do not exist.

- [ ] **Step 3: Implement the immutable structs and pure normalizer**

Use explicit structs and tuples:

```elixir
defmodule GSMLG.ProxyRules.ZeroOmega.Policy do
  @enforce_keys [:revision, :default_action, :rules]
  defstruct @enforce_keys
end

defmodule GSMLG.ProxyRules.ZeroOmega.Rule do
  @enforce_keys [:id, :priority, :enabled, :condition, :action, :input_order]
  defstruct @enforce_keys ++ [note: nil]
end

defmodule GSMLG.ProxyRules.ZeroOmega.Diagnostic do
  @enforce_keys [:severity, :code, :message]
  defstruct @enforce_keys ++ [rule_id: nil, field: nil]
end
```

Implement `normalize_policy/1` as one deterministic pipeline. Use
`GSMLG.ProxyRules.Domain.normalize/1` for domain and host values; use `URI` for
URLs; `Regex.compile/1` for regex validation; and `:inet.parse_address/1` plus
prefix-range checks for CIDR. Reject bytes `0..31` and `127` from all line-based
fields. Sort with `{priority, input_order}`, then deduplicate on
`{condition, action}` while retaining the first rule.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the same focused test. Expected: all Normalizer tests pass with zero failures.

- [ ] **Step 5: Commit the slice**

```bash
git add apps/proxy_rules/lib/gsmlg/proxy_rules/zero_omega/{policy,rule,diagnostic,normalizer}.ex apps/proxy_rules/test/gsmlg/proxy_rules/zero_omega/normalizer_test.exs
git commit -m "feat(proxy-rules): normalize ZeroOmega policies"
```

## Task 2: SwitchyOmega Conditions Renderer

**Files:**
- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/zero_omega/switchy.ex`
- Create: `apps/proxy_rules/test/gsmlg/proxy_rules/zero_omega/switchy_test.exs`
- Create: `apps/proxy_rules/test/fixtures/zero_omega/switchy_binary.txt`
- Create: `apps/proxy_rules/test/fixtures/zero_omega/switchy_result.txt`

- [ ] **Step 1: Write failing Switchy tests and golden fixtures**

The table-driven unit test must assert every mapping:

```elixir
for {condition, expected} <- [
      {{:domain_suffix, "example.com"}, "*.example.com"},
      {{:host_exact, "example.com"}, "example.com"},
      {{:host_glob, "api-*.example.com"}, "HostWildcard: api-*.example.com"},
      {{:url_prefix, "https://example.com/api/"}, "UrlWildcard: https://example.com/api/*"},
      {{:url_glob, "https://*.example.com/*"}, "UrlWildcard: https://*.example.com/*"},
      {{:url_regex, "^https://example\\.com/"}, "UrlRegex: ^https://example\\.com/"},
      {{:cidr, "10.0.0.0/8"}, "Ip: 10.0.0.0/8"},
      {{:keyword, "example"}, "Keyword: example"}
    ] do
  test "renders #{inspect(condition)}" do
    assert {:ok, body} = Switchy.render(policy_with(unquote(Macro.escape(condition))), mode: :binary, match_profile: "squid", default_profile: "direct")
    assert body =~ unquote(expected)
  end
end
```

Add explicit tests for Direct `!`, input ordering, `@note`, prefix `*`
idempotence, special-leading host-glob `: ` escape, third-profile binary
rejection, result-mode third profiles, final `* +direct`, ambiguous profile
rejection, CRLF-only endings, a final CRLF, repeatability, and exact equality
with both fixture files.

- [ ] **Step 2: Run Switchy tests and verify RED**

```bash
devenv shell -- mix test apps/proxy_rules/test/gsmlg/proxy_rules/zero_omega/switchy_test.exs
```

Expected: compilation fails because `ZeroOmega.Switchy` is undefined.

- [ ] **Step 3: Implement binary and result rendering**

Expose:

```elixir
@spec render(Policy.t(), keyword()) :: {:ok, binary()} | {:error, [Diagnostic.t()]}
def render(policy, options)
```

Validate `mode`, `match_profile`, and `default_profile` without reading
application configuration. Serialize notes immediately before their rule.
Preserve normalized policy order. Build iodata, join with `"\r\n"`, and always
append one final CRLF. Result mode emits `@with result` and the final
`* +<default-profile>` line.

- [ ] **Step 4: Run Switchy tests and verify GREEN**

Expected: all Switchy unit and golden tests pass.

- [ ] **Step 5: Commit the slice**

```bash
git add apps/proxy_rules/lib/gsmlg/proxy_rules/zero_omega/switchy.ex apps/proxy_rules/test/gsmlg/proxy_rules/zero_omega/switchy_test.exs apps/proxy_rules/test/fixtures/zero_omega/switchy_*.txt
git commit -m "feat(proxy-rules): render SwitchyOmega conditions"
```

## Task 3: Parameterized PAC Renderer

**Files:**
- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/zero_omega/pac.ex`
- Create: `apps/proxy_rules/test/gsmlg/proxy_rules/zero_omega/pac_test.exs`
- Create: `apps/proxy_rules/test/fixtures/zero_omega/proxy.pac`

- [ ] **Step 1: Write failing proxy-validation and PAC golden tests**

Cover DNS/IPv4/bracketed-IPv6 success, hostname lowercase canonicalization,
ports 1 and 65535, and rejection of missing ports, port zero/overflow, schemes,
credentials, paths, whitespace, quotes, backslashes, CR/LF/NUL, and duplicate
option values at the HTTP boundary.

Use an operational policy with a Direct rule followed by Proxy rules:

```elixir
assert {:ok, body} = PAC.render(policy, proxy: "10.100.0.1:3128")
assert body =~ "var proxy = 'PROXY 10.100.0.1:3128';\r\n"
assert body =~ ~s("internal.example.com")
assert body =~ ~s("google.com")
assert body =~ "return 'DIRECT';"
assert body =~ "return proxy;"
assert body == File.read!(fixture_path("proxy.pac"))
```

Add a semantic test that evaluates or directly tests the emitted helper logic
against `example.com`, `www.example.com`, `notexample.com`, and
`example.com.attacker.test`. Add unsupported-condition and third-profile error
tests. Assert CRLF-only final output and deterministic repeated rendering.

- [ ] **Step 2: Run PAC tests and verify RED**

```bash
devenv shell -- mix test apps/proxy_rules/test/gsmlg/proxy_rules/zero_omega/pac_test.exs
```

Expected: compilation fails because `ZeroOmega.PAC` is undefined.

- [ ] **Step 3: Implement strict proxy parsing and deterministic PAC JavaScript**

Expose:

```elixir
@spec normalize_proxy(binary()) :: {:ok, binary()} | {:error, Diagnostic.t()}
@spec validate_policy(Policy.t()) :: :ok | {:error, [Diagnostic.t()]}
@spec render(Policy.t(), keyword()) :: {:ok, binary()} | {:error, [Diagnostic.t()]}
```

Render fixed ES5-compatible JavaScript. Use arrays of canonical ASCII domain
strings and this label-boundary helper instead of substring matching:

```javascript
function domainMatches(host, domain) {
  return host === domain ||
    (host.length > domain.length &&
      host.slice(-(domain.length + 1)) === '.' + domain);
}
```

`FindProxyForURL` lowercases `host`, checks Direct domains first, Proxy domains
second, then returns `DIRECT`. Use a fixed layout and CRLF lines; do not emit a
timestamp or request metadata.

- [ ] **Step 4: Run PAC tests and verify GREEN**

Expected: all proxy validation, PAC semantic, and golden tests pass.

- [ ] **Step 5: Commit the slice**

```bash
git add apps/proxy_rules/lib/gsmlg/proxy_rules/zero_omega/pac.ex apps/proxy_rules/test/gsmlg/proxy_rules/zero_omega/pac_test.exs apps/proxy_rules/test/fixtures/zero_omega/proxy.pac
git commit -m "feat(proxy-rules): render parameterized PAC files"
```

## Task 4: Rendered Result and Export Pipeline

**Files:**
- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/zero_omega/rendered_rule_list.ex`
- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/zero_omega/export.ex`
- Create: `apps/proxy_rules/test/gsmlg/proxy_rules/zero_omega/export_test.exs`

- [ ] **Step 1: Write failing pipeline and metadata tests**

Assert the functional contract:

```elixir
assert {:ok, %RenderedRuleList{} = rendered} =
         policy
         |> Export.normalize()
         |> Export.validate_for(:switchy, mode: :binary, match_profile: "squid", default_profile: "direct")
         |> Export.render(:switchy, mode: :binary, match_profile: "squid", default_profile: "direct")

assert rendered.body =~ "[SwitchyOmega Conditions]\r\n"
assert rendered.content_type == "text/plain; charset=utf-8"
assert rendered.format == :switchy
assert rendered.revision == policy.revision
assert rendered.checksum == Base.encode16(:crypto.hash(:sha256, rendered.body), case: :lower)
assert rendered.etag == ~s("sha256-#{rendered.checksum}")
```

Repeat for PAC and assert failed validation cannot reach rendering. Test that
equivalent canonical options yield byte-identical output and metadata.

- [ ] **Step 2: Run Export tests and verify RED**

```bash
devenv shell -- mix test apps/proxy_rules/test/gsmlg/proxy_rules/zero_omega/export_test.exs
```

Expected: `RenderedRuleList` and `Export` are undefined.

- [ ] **Step 3: Implement explicit pipeline result types**

Use tagged intermediate tuples rather than hidden mutable state:

```elixir
def normalize(%Policy{} = policy), do: Normalizer.normalize_policy(policy)

def validate_for({:ok, policy}, format, options),
  do: validate_format(policy, format, options)

def render({:ok, policy}, format, options),
  do: build_rendered(policy, format, options)

def validate_for({:error, diagnostics}, _format, _options), do: {:error, diagnostics}
def render({:error, diagnostics}, _format, _options), do: {:error, diagnostics}
```

`RenderedRuleList` stores `body`, `content_type`, `format`, `revision`,
`checksum`, `etag`, and `content_length`. The HTTP boundary supplies
`last_modified` from the Snapshot rather than inserting a clock value here.

- [ ] **Step 4: Run Export tests and verify GREEN**

- [ ] **Step 5: Commit the slice**

```bash
git add apps/proxy_rules/lib/gsmlg/proxy_rules/zero_omega/{rendered_rule_list,export}.ex apps/proxy_rules/test/gsmlg/proxy_rules/zero_omega/export_test.exs
git commit -m "feat(proxy-rules): add ZeroOmega export pipeline"
```

## Task 5: Compile and Persist the Atomic ZeroOmega Policy

**Files:**
- Modify: `apps/proxy_rules/lib/gsmlg/proxy_rules/compiler.ex`
- Modify: `apps/proxy_rules/lib/gsmlg/proxy_rules/snapshot.ex`
- Modify: `apps/proxy_rules/lib/gsmlg/proxy_rules/persistence.ex`
- Modify: `apps/proxy_rules/test/gsmlg/proxy_rules/compiler_test.exs`
- Modify: `apps/proxy_rules/test/gsmlg/proxy_rules/persistence_test.exs`
- Modify: `apps/proxy_rules/test/gsmlg/proxy_rules/publication_concurrency_test.exs`

- [ ] **Step 1: Write failing compiler and persistence assertions**

Extend the compiler fixture assertion:

```elixir
assert %Policy{revision: "12", default_action: :default, rules: rules} =
         snapshot.zeroomega_policy
assert [%Rule{action: :default}, %Rule{action: :match} | _] = rules
assert :ok = PAC.validate_policy(snapshot.zeroomega_policy)
```

The stored policy must not bake request profile names into persistent state.
Map current `:direct` rules to canonical `:default` and current `:proxy` rules
to canonical `:match`. Resolve those actions with `default_profile` and
`match_profile` inside `Export`; keep explicit `{:profile, name}` actions for
pure result-mode tests and future sources.

Add persistence tests proving artifact envelope version 3 accepts a validated
policy, version 2 is incompatible, remote envelope version 1 remains readable,
and malformed policy structs are rejected. Extend the concurrency assertion to
check `zeroomega_policy.revision` matches `generation` and contains only domains
from that same generation.

- [ ] **Step 2: Run compiler, persistence, and concurrency tests and verify RED**

```bash
devenv shell -- mix test \
  apps/proxy_rules/test/gsmlg/proxy_rules/compiler_test.exs \
  apps/proxy_rules/test/gsmlg/proxy_rules/persistence_test.exs \
  apps/proxy_rules/test/gsmlg/proxy_rules/publication_concurrency_test.exs
```

Expected: missing `zeroomega_policy` field and version assertions fail.

- [ ] **Step 3: Build the operational policy during compilation**

After hierarchy folding, create deterministic rules with Direct first and
Proxy second. Use stable IDs containing source/action/domain or a content hash,
monotonic priorities, and explicit `input_order`. Normalize and validate both
Switchy and PAC compatibility before constructing `%Snapshot{}`. Return
structured compile diagnostics on failure rather than publishing a partial
policy.

Add `:zeroomega_policy` to `Snapshot` enforce keys and metadata. Update
Persistence exact-key validation, bounded string/list sizes, safe condition and
action validation, and aggregate snapshot-size limits. Increment only
`@artifact_version` from 2 to 3; leave `@remote_version` at 1.

- [ ] **Step 4: Run the focused integration tests and verify GREEN**

- [ ] **Step 5: Run the complete Proxy Rules suite**

```bash
devenv shell -- mix test apps/proxy_rules/test
```

Expected: all Proxy Rules tests and properties pass with zero failures.

- [ ] **Step 6: Commit the slice**

```bash
git add apps/proxy_rules/lib/gsmlg/proxy_rules/{compiler,snapshot,persistence}.ex apps/proxy_rules/test/gsmlg/proxy_rules/{compiler_test,persistence_test,publication_concurrency_test}.exs
git commit -m "feat(proxy-rules): publish ZeroOmega policies atomically"
```

## Task 6: Facade and Phoenix HTTP Publication

**Files:**
- Modify: `apps/proxy_rules/lib/gsmlg/proxy_rules.ex`
- Create: `apps/gsmlg_web/lib/gsmlg/web/controllers/zero_omega_rules_controller.ex`
- Modify: `apps/gsmlg_web/lib/gsmlg/web/router.ex`
- Create: `apps/gsmlg_web/test/gsmlg_web/controllers/zero_omega_rules_controller_test.exs`

- [ ] **Step 1: Write failing controller contract tests**

Add tests for:

```elixir
conn = get(conn, "/rules/zeroomega/switchy")
assert response(conn, 200) =~ "[SwitchyOmega Conditions]\r\n"
assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
assert get_resp_header(conn, "cache-control") == ["no-cache"]

conn = get(recycle(conn), "/rules/zeroomega/pac?proxy=10.100.0.1%3A3128")
assert response(conn, 200) =~ "var proxy = 'PROXY 10.100.0.1:3128';\r\n"
assert get_resp_header(conn, "content-type") ==
         ["application/x-ns-proxy-autoconfig; charset=utf-8"]
```

Also cover result mode/profile rendering, stable ETag, equivalent canonical
proxy values, weak/comma-separated/asterisk `If-None-Match`, 304, HEAD with GET
content length and empty body, missing/invalid/duplicate/unknown query values as
400, empty Store as 503, no proxy value or credentials in telemetry/error
messages, and generation/Last-Modified headers.

Use `URI.query_decoder/2` over `conn.query_string` to preserve query pairs and
detect duplicates before converting to a map.

- [ ] **Step 2: Run controller tests and verify RED**

```bash
devenv shell -- mix test apps/gsmlg_web/test/gsmlg_web/controllers/zero_omega_rules_controller_test.exs
```

Expected: routes return 404 and the controller is undefined.

- [ ] **Step 3: Add one-read facade and controller**

Add a facade function shaped as:

```elixir
@spec export_zeroomega(:switchy | :pac, keyword()) ::
        {:ok, %{generation: non_neg_integer(), compiled_at: DateTime.t(), output: RenderedRuleList.t()}}
        | {:error, :not_ready | :not_found | [Diagnostic.t()]}
```

It calls `Store.current/0` once, extracts `generation`, `compiled_at`, and the
policy, then calls the pure Export pipeline. The controller owns HTTP option
decoding, status mapping, ETag comparison, response headers, HEAD semantics,
and bounded plain-text errors. Never log the raw `proxy` query value.

Add public GET routes before the `/api` catch-all and rely on existing
`Plug.Head` to convert HEAD while preserving GET headers and suppressing the
body. If controller tests show Phoenix routing does not reach GET for HEAD, add
explicit `head` routes to the same actions.

- [ ] **Step 4: Run controller tests and verify GREEN**

- [ ] **Step 5: Run existing artifact controller tests for regression**

```bash
devenv shell -- mix test \
  apps/gsmlg_web/test/gsmlg_web/controllers/proxy_rules_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/zero_omega_rules_controller_test.exs
```

Expected: existing Raw/Squid/Clash behavior and new endpoints all pass.

- [ ] **Step 6: Commit the slice**

```bash
git add apps/proxy_rules/lib/gsmlg/proxy_rules.ex apps/gsmlg_web/lib/gsmlg/web/{router.ex,controllers/zero_omega_rules_controller.ex} apps/gsmlg_web/test/gsmlg_web/controllers/zero_omega_rules_controller_test.exs
git commit -m "feat(web): publish ZeroOmega rule exports"
```

## Task 7: Last-Known-Good, Concurrent Reads, and Documentation

**Files:**
- Modify: `apps/proxy_rules/test/gsmlg/proxy_rules/publication_concurrency_test.exs`
- Modify: `apps/proxy_rules/test/gsmlg/proxy_rules/coordinator_test.exs`
- Modify: `apps/proxy_rules/README.md`
- Modify: `apps/proxy_rules/test/gsmlg/proxy_rules/operational_test.exs`

- [ ] **Step 1: Write failing last-known-good and documentation tests**

Add a Coordinator test that publishes generation 1, injects a compiler result
with an invalid ZeroOmega policy for generation 2, and asserts Store still
returns generation 1 with its complete policy. Extend concurrent readers to
render both Switchy and PAC from every observed snapshot and assert each body
contains only that snapshot's generation domains.

Extend operational documentation assertions to require these literal routes:

```text
/rules/zeroomega/switchy
/rules/zeroomega/switchy?mode=result&match_profile=squid&default_profile=direct
/rules/zeroomega/pac?proxy=10.100.0.1:3128
```

- [ ] **Step 2: Run focused tests and verify RED**

```bash
devenv shell -- mix test \
  apps/proxy_rules/test/gsmlg/proxy_rules/coordinator_test.exs \
  apps/proxy_rules/test/gsmlg/proxy_rules/publication_concurrency_test.exs \
  apps/proxy_rules/test/gsmlg/proxy_rules/operational_test.exs
```

- [ ] **Step 3: Complete bounded failure mapping and user documentation**

Document ZeroOmega UI placement, query parameters/defaults, examples, MIME
types, Direct-before-Proxy behavior, proxy validation, ETag/HEAD behavior, and
the unsupported operational condition set. Ensure Coordinator maps exporter
validation failure to a bounded operational error and emits structured
diagnostic codes without rule bodies or proxy options.

- [ ] **Step 4: Run focused tests and verify GREEN**

- [ ] **Step 5: Commit the slice**

```bash
git add apps/proxy_rules/README.md apps/proxy_rules/test/gsmlg/proxy_rules/{coordinator_test,publication_concurrency_test,operational_test}.exs
git commit -m "docs(proxy-rules): document ZeroOmega exports"
```

## Task 8: Complete Verification and Review

**Files:**
- Modify only files required by failures caused by this feature.

- [ ] **Step 1: Format all touched Elixir files**

```bash
devenv shell -- mix format \
  apps/proxy_rules/lib/gsmlg/proxy_rules.ex \
  apps/proxy_rules/lib/gsmlg/proxy_rules/{compiler,snapshot,persistence}.ex \
  apps/proxy_rules/lib/gsmlg/proxy_rules/zero_omega/*.ex \
  apps/proxy_rules/test/gsmlg/proxy_rules/zero_omega/*.exs \
  apps/proxy_rules/test/gsmlg/proxy_rules/{compiler_test,persistence_test,publication_concurrency_test,coordinator_test,operational_test}.exs \
  apps/gsmlg_web/lib/gsmlg/web/{router.ex,controllers/zero_omega_rules_controller.ex} \
  apps/gsmlg_web/test/gsmlg_web/controllers/zero_omega_rules_controller_test.exs
```

- [ ] **Step 2: Run the complete relevant tests**

```bash
devenv shell -- mix test apps/proxy_rules/test
devenv shell -- mix test \
  apps/gsmlg_web/test/gsmlg_web/controllers/proxy_rules_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/zero_omega_rules_controller_test.exs
```

Expected: all tests and properties pass with zero failures.

- [ ] **Step 3: Compile affected applications with warnings as errors**

```bash
devenv shell -- mix compile --warnings-as-errors
```

If unrelated pre-existing warnings outside `proxy_rules` or `gsmlg_web` fail
the umbrella compile, record exact files and run scoped application compiles;
do not repair unrelated warnings.

- [ ] **Step 4: Check formatting and whitespace**

```bash
devenv shell -- mix format --check-formatted
git diff --check
git status --short --branch
```

- [ ] **Step 5: Perform requirement-by-requirement code review**

Confirm the diff contains no AutoProxy exporter, no new process/database, no
GFWList parser broadening, no raw proxy logging, no request-time timestamps,
and no unrelated edits. Confirm both endpoints use one immutable Snapshot read,
content-derived ETags, CRLF output, final CRLF, 304, and HEAD.

- [ ] **Step 6: Commit any verification-only correction**

Only if Step 1-5 required a feature-scoped correction:

```bash
git add apps/proxy_rules apps/gsmlg_web/lib/gsmlg/web/controllers/zero_omega_rules_controller.ex apps/gsmlg_web/lib/gsmlg/web/router.ex apps/gsmlg_web/test/gsmlg_web/controllers/zero_omega_rules_controller_test.exs
git commit -m "fix(proxy-rules): complete ZeroOmega export verification"
```

Do not push, release, deploy, or merge unless separately requested.
