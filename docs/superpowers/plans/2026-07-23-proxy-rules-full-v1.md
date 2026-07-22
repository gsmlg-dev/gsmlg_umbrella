# Proxy Rules Full V1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the domain-only proxy-rules service, its six public download endpoints, and the operational admin dashboard defined in the approved full V1 specification.

**Architecture:** Pure parsers and compilers transform immutable remote and local source snapshots into one pre-rendered artifact generation. Supervised source services own HTTP and filesystem scheduling, a generation-aware Coordinator runs compilation in unlinked tasks, and a protected ETS Store publishes complete snapshots atomically after durable persistence. Phoenix applications consume only the stable facade.

**Tech Stack:** Elixir 1.18, OTP 28, ETS, Finch, FileSystem, `:idna`, `:telemetry`, StreamData, Phoenix 1.8, LiveView 1.2, Phoenix DuskMoon, ExUnit.

---

## Scope and Execution Rules

- Implement only the approved specification at
  `docs/superpowers/specs/2026-07-23-proxy-rules-full-v1-design.md`.
- Preserve the fixed public facade and fixed HTTP routes.
- Do not add rule editing, runtime configuration editing, another endpoint,
  Ecto, Oban, or another remote source.
- Work in `.trees/proxy-rules-full-v1` on branch
  `codex/proxy-rules-full-v1`.
- Prefix Mix commands with `unbuffer` inside `devenv shell`.
- Run only the task's scoped tests during implementation. If an unrelated test
  fails, record it and stop rather than repairing it.
- Every task is test-first and ends with its own conventional commit.

## File Map

### Pure domain and compilation

- `apps/proxy_rules/lib/gsmlg/proxy_rules/configuration.ex` — immutable runtime settings.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/domain.ex` — IDNA hostname normalization.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/rule.ex` — normalized rule struct.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/diagnostic.ex` — bounded diagnostic entry.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/parse_result.ex` — parser result and counters.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/parser/local.ex` — local one-domain-per-line parser.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/parser/gfwlist.ex` — Base64 decode and safe Adblock classification.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/hierarchy.ex` — exact deduplication and intra-list folding.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/renderer.ex` — raw, Squid, and Clash rendering.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/output.ex` — one rendered HTTP artifact.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/snapshot.ex` — complete published generation.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/compiler.ex` — pure end-to-end compilation.

### Runtime services

- `apps/proxy_rules/lib/gsmlg/proxy_rules/persistence.ex` — versioned checksummed atomic files.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/telemetry.ex` — bounded event and log helpers.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/transport.ex` — remote transport behavior.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/transport/finch.ex` — bounded streaming HTTP transport.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/source_snapshot.ex` — versioned remote/local source values.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/source/remote.ex` — conditional fetch and retry service.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/source/local.ex` — directory watcher and reconciler.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/coordinator.ex` — generation and task authority.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/store.ex` — protected ETS reads and serialized writes.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/supervisor.ex` — completed fixed tree.
- `apps/proxy_rules/lib/gsmlg/proxy_rules.ex` — stable facade.

### Web, operations, and tests

- `apps/gsmlg_web/lib/gsmlg/web/controllers/proxy_rules_controller.ex` — public artifact delivery.
- `apps/gsmlg_web/lib/gsmlg/web/router.ex` — fixed public routes.
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/proxy_rules_telemetry_bridge.ex` — telemetry-to-PubSub bridge.
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/proxy_rules_live/index.ex` — complete dashboard.
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/application.ex` — supervise the bridge.
- `apps/proxy_rules/test/fixtures/gfwlist/` — attributed real and focused synthetic fixtures.
- `apps/proxy_rules/bench/proxy_rules_benchmark.exs` — reproducible benchmark.
- `apps/proxy_rules/README.md` — runtime and downstream operator guide.
- `Dockerfile`, `Dockerfile.alpine`, `Dockerfile.lite`, `docs/deploy.md` — runtime directories and permissions.

Test files mirror each module under `apps/proxy_rules/test/`, with controller
tests under `apps/gsmlg_web/test/` and LiveView/bridge tests under
`apps/gsmlg_admin_web/test/`.

### Task 1: Add Runtime Dependencies and Immutable Configuration

**Files:**

- Modify: `apps/proxy_rules/mix.exs`
- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/configuration.ex`
- Create: `apps/proxy_rules/test/gsmlg/proxy_rules/configuration_test.exs`

- [ ] **Step 1: Write the failing configuration tests**

```elixir
defmodule GSMLG.ProxyRules.ConfigurationTest do
  use ExUnit.Case, async: true

  alias GSMLG.ProxyRules.Configuration

  test "builds immutable settings from a validated map" do
    assert {:ok, config} =
             Configuration.new(%{
               source_url: "https://example.test/list",
               remote_refresh_interval: 60_000,
               remote_connect_timeout: 500,
               remote_receive_timeout: 1_000,
               remote_max_body_size: 4_096,
               retry_min_interval: 100,
               retry_max_interval: 1_000,
               retry_jitter: false,
               local_proxy_list_path: "/tmp/proxy.txt",
               local_direct_list_path: "/tmp/direct.txt",
               local_watch_debounce: 25,
               local_reconciliation_interval: 250,
               state_directory: "/tmp/state",
               cache_control: "public, max-age=60",
               unsupported_rule_sample_limit: 3
             })

    assert %Configuration{source_url: "https://example.test/list", retry_jitter: false} = config
  end

  test "rejects a map missing validated settings" do
    assert {:error, {:missing_setting, :source_url}} = Configuration.new(%{})
  end
end
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
devenv shell -- unbuffer mix test apps/proxy_rules/test/gsmlg/proxy_rules/configuration_test.exs
```

Expected: compilation fails because `GSMLG.ProxyRules.Configuration` is undefined.

- [ ] **Step 3: Add focused dependencies**

Update `deps/0` in `apps/proxy_rules/mix.exs`:

```elixir
defp deps do
  [
    {:finch, "~> 0.23"},
    {:file_system, "~> 1.1"},
    {:idna, "~> 7.1"},
    {:telemetry, "~> 1.3"},
    {:gsmlg_telemetry, in_umbrella: true},
    {:stream_data, "~> 1.3", only: [:dev, :test]},
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
    {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
  ]
end
```

- [ ] **Step 4: Implement the configuration struct**

Create a struct containing the 15 fixed keys, an `@required` list, and:

```elixir
@spec new(map()) :: {:ok, t()} | {:error, {:missing_setting, atom()}}
def new(settings) when is_map(settings) do
  case Enum.find(@required, &(not Map.has_key?(settings, &1))) do
    nil -> {:ok, struct!(__MODULE__, Map.take(settings, @required))}
    key -> {:error, {:missing_setting, key}}
  end
end

@spec load() :: {:ok, t()} | {:error, {:missing_setting, atom()}}
def load do
  :proxy_rules
  |> Application.get_env(:settings, %{})
  |> new()
end
```

Define the complete type:

```elixir
@type t :: %__MODULE__{
        source_url: String.t(),
        remote_refresh_interval: pos_integer(),
        remote_connect_timeout: pos_integer(),
        remote_receive_timeout: pos_integer(),
        remote_max_body_size: pos_integer(),
        retry_min_interval: pos_integer(),
        retry_max_interval: pos_integer(),
        retry_jitter: boolean(),
        local_proxy_list_path: String.t(),
        local_direct_list_path: String.t(),
        local_watch_debounce: pos_integer(),
        local_reconciliation_interval: pos_integer(),
        state_directory: String.t(),
        cache_control: String.t(),
        unsupported_rule_sample_limit: pos_integer()
      }
```

- [ ] **Step 5: Verify GREEN and commit**

Run:

```bash
devenv shell -- unbuffer mix test apps/proxy_rules/test/gsmlg/proxy_rules/configuration_test.exs
git add apps/proxy_rules/mix.exs apps/proxy_rules/lib/gsmlg/proxy_rules/configuration.ex apps/proxy_rules/test/gsmlg/proxy_rules/configuration_test.exs mix.lock
git commit -m "build(proxy-rules): add runtime dependencies"
```

Expected: 2 tests, 0 failures; commit succeeds.

### Task 2: Normalize Domains and Define Typed Parser Values

**Files:**

- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/domain.ex`
- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/rule.ex`
- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/diagnostic.ex`
- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/parse_result.ex`
- Create: `apps/proxy_rules/test/gsmlg/proxy_rules/domain_test.exs`
- Create: `apps/proxy_rules/test/gsmlg/proxy_rules/domain_property_test.exs`

- [ ] **Step 1: Write normalization examples and properties**

```elixir
defmodule GSMLG.ProxyRules.DomainTest do
  use ExUnit.Case, async: true

  alias GSMLG.ProxyRules.Domain

  test "normalizes suffix dots, case, URL hosts, ports, and IDNA" do
    assert {:ok, %Domain{name: "example.com", reversed_labels: ["com", "example"]}} =
             Domain.normalize(" .Example.COM. ")

    assert {:ok, %Domain{name: "example.com"}} =
             Domain.normalize("https://Example.com:443")

    assert {:ok, %Domain{name: "xn--bcher-kva.example"}} =
             Domain.normalize("bücher.example")
  end

  test "rejects IPs, wildcard placement, malformed labels, and excessive lengths" do
    for value <- ["127.0.0.1", "*.example.com", "bad_label.example", "-bad.example", "bad-.example"] do
      assert {:error, _reason} = Domain.normalize(value)
    end
  end
end
```

```elixir
defmodule GSMLG.ProxyRules.DomainPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias GSMLG.ProxyRules.Domain

  property "normalization is idempotent" do
    check all labels <- list_of(string(:alphanumeric, min_length: 1, max_length: 10), min_length: 2, max_length: 4) do
      candidate = Enum.join(labels, ".")

      case Domain.normalize(candidate) do
        {:ok, domain} -> assert {:ok, ^domain} = Domain.normalize(domain.name)
        {:error, _reason} -> :ok
      end
    end
  end
end
```

- [ ] **Step 2: Verify RED**

Run:

```bash
devenv shell -- unbuffer mix test apps/proxy_rules/test/gsmlg/proxy_rules/domain_test.exs apps/proxy_rules/test/gsmlg/proxy_rules/domain_property_test.exs
```

Expected: undefined `Domain` and parser value modules.

- [ ] **Step 3: Define focused structs**

```elixir
defmodule GSMLG.ProxyRules.Domain do
  @enforce_keys [:name, :reversed_labels]
  defstruct [:name, :reversed_labels]
  @type t :: %__MODULE__{name: String.t(), reversed_labels: [String.t()]}
end

defmodule GSMLG.ProxyRules.Rule do
  @enforce_keys [:domain, :action, :source, :location]
  defstruct [:domain, :action, :source, :location, match: :suffix]
end

defmodule GSMLG.ProxyRules.Diagnostic do
  @enforce_keys [:kind, :source, :location, :reason]
  defstruct [:kind, :source, :location, :reason, :sample]
end

defmodule GSMLG.ProxyRules.ParseResult do
  defstruct rules: [], counts: %{accepted: 0, invalid: 0, unsupported: 0}, diagnostics: []
end
```

- [ ] **Step 4: Implement one normalizer**

Implement `Domain.normalize/1` as a pipeline of small private functions:

```elixir
@spec normalize(String.t()) :: {:ok, t()} | {:error, atom()}
def normalize(value) when is_binary(value) do
  with {:ok, host} <- extract_host(String.trim(value)),
       host <- host |> String.trim_leading(".") |> String.trim_trailing("."),
       {:ok, ascii} <- to_ascii(host),
       ascii <- String.downcase(ascii),
       :ok <- validate_ascii(ascii) do
    {:ok, %__MODULE__{name: ascii, reversed_labels: ascii |> String.split(".") |> Enum.reverse()}}
  end
end
```

`extract_host/1` accepts a bare domain or an HTTP/HTTPS URI with no path beyond
`""` or `"/"`, no query, and no fragment. `to_ascii/1` calls
`:idna.encode/1`, converts the returned charlist to a binary, and maps library
errors to `{:error, :invalid_idna}`. `validate_ascii/1` rejects IP literals,
non `[a-z0-9-]` label characters, empty labels, edge hyphens, labels over 63
bytes, and total length over 253 bytes.

- [ ] **Step 5: Verify GREEN and commit**

Run:

```bash
devenv shell -- unbuffer mix test apps/proxy_rules/test/gsmlg/proxy_rules/domain_test.exs apps/proxy_rules/test/gsmlg/proxy_rules/domain_property_test.exs
git add apps/proxy_rules/lib/gsmlg/proxy_rules/{domain,rule,diagnostic,parse_result}.ex apps/proxy_rules/test/gsmlg/proxy_rules/domain*_test.exs
git commit -m "feat(proxy-rules): normalize domain rules"
```

Expected: all examples and generated properties pass.

### Task 3: Parse Local Lists and Fold Hierarchies

**Files:**

- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/parser/local.ex`
- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/hierarchy.ex`
- Create: `apps/proxy_rules/test/gsmlg/proxy_rules/parser/local_test.exs`
- Create: `apps/proxy_rules/test/gsmlg/proxy_rules/hierarchy_test.exs`
- Create: `apps/proxy_rules/test/gsmlg/proxy_rules/hierarchy_property_test.exs`

- [ ] **Step 1: Write local parsing and folding tests**

```elixir
test "parses comments and keeps bounded invalid diagnostics" do
  text = "# comment\n.Example.com.\n! ignored\nbad_label.example\napi.example.com\n"

  assert %ParseResult{
           rules: [%Rule{domain: %Domain{name: "example.com"}}, %Rule{domain: %Domain{name: "api.example.com"}}],
           counts: %{accepted: 2, invalid: 1, unsupported: 0},
           diagnostics: [%Diagnostic{kind: :invalid}]
         } = Local.parse(text, :proxy, :local_proxy, 1)
end
```

```elixir
test "folds descendants only within one list" do
  rules = rules(~w(example.com api.example.com other.org), :proxy)
  assert ["example.com", "other.org"] == rules |> Hierarchy.fold() |> Enum.map(& &1.domain.name)
end

property "duplicates and descendants cannot change folded output" do
  check all prefix <- string(:alphanumeric, min_length: 1, max_length: 8) do
    parent = rule("example.com", :proxy)
    child = rule("#{prefix}.example.com", :proxy)
    assert Hierarchy.fold([parent]) == Hierarchy.fold([child, parent, parent])
  end
end
```

- [ ] **Step 2: Verify RED**

Run the three new test files and expect undefined `Parser.Local` and `Hierarchy` modules.

- [ ] **Step 3: Implement the local parser**

`Local.parse/4` splits on Unicode line breaks, enumerates one-based line
numbers, ignores blank/comment lines, normalizes each remaining line, and
prepends accepted rules and diagnostics before reversing them. Add a diagnostic
only while `length(diagnostics) < sample_limit`, but always increment complete
counts.

```elixir
@spec parse(binary(), :proxy | :direct, atom(), non_neg_integer()) :: ParseResult.t()
def parse(text, action, source, sample_limit) do
  text
  |> String.split(~r/\R/u)
  |> Enum.with_index(1)
  |> Enum.reduce(%ParseResult{}, &parse_line(&1, &2, action, source, sample_limit))
  |> reverse_collections()
end
```

- [ ] **Step 4: Implement deterministic hierarchy folding**

Sort by `{reversed_labels, domain.name}`. Reduce in sorted order and keep a
rule only when no previously kept suffix is a prefix of its reversed labels.
Return the kept rules lexicographically sorted by `domain.name`. Exact
duplicates count separately through `Hierarchy.fold_with_stats/1`:

```elixir
@spec fold_with_stats([Rule.t()]) :: %{rules: [Rule.t()], duplicate_count: non_neg_integer(), collapsed_count: non_neg_integer()}
def fold_with_stats(rules) do
  unique = Enum.uniq_by(rules, & &1.domain.name)
  folded = fold_unique(unique)

  %{
    rules: folded,
    duplicate_count: length(rules) - length(unique),
    collapsed_count: length(unique) - length(folded)
  }
end
```

- [ ] **Step 5: Verify GREEN and commit**

Run the three tests, then:

```bash
git add apps/proxy_rules/lib/gsmlg/proxy_rules/parser/local.ex apps/proxy_rules/lib/gsmlg/proxy_rules/hierarchy.ex apps/proxy_rules/test/gsmlg/proxy_rules/{parser,hierarchy*}
git commit -m "feat(proxy-rules): compile local domain lists"
```

### Task 4: Render and Build Complete Artifacts

**Files:**

- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/renderer.ex`
- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/output.ex`
- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/snapshot.ex`
- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/compiler.ex`
- Create: `apps/proxy_rules/test/gsmlg/proxy_rules/renderer_test.exs`
- Create: `apps/proxy_rules/test/gsmlg/proxy_rules/compiler_test.exs`
- Create: `apps/proxy_rules/test/gsmlg/proxy_rules/compiler_property_test.exs`

- [ ] **Step 1: Write deterministic output tests**

```elixir
test "renders all formats with exact trailing newline semantics" do
  rules = rules(~w(example.com google.com), :proxy)

  assert "example.com\ngoogle.com\n" == Renderer.render(rules, :raw)
  assert ".example.com\n.google.com\n" == Renderer.render(rules, :squid)
  assert "DOMAIN-SUFFIX,example.com\nDOMAIN-SUFFIX,google.com\n" == Renderer.render(rules, :clash)
  assert "" == Renderer.render([], :raw)
end
```

```elixir
test "compiles lists independently and records same-domain conflicts" do
  input = %{
    remote: Base.encode64("||example.com^\n@@||direct.example.com^\n@@||example.com^\n"),
    local_proxy: "api.example.com\n",
    local_direct: "internal.example.com\n"
  }

  assert {:ok, %Snapshot{} = snapshot} = Compiler.compile(input, generation: 7, sample_limit: 10)
  assert snapshot.generation == 7
  assert snapshot.statistics.conflict_count == 1
  assert snapshot.rendered_outputs.proxy.raw.body == "example.com\n"
  assert snapshot.rendered_outputs.direct.raw.body == "direct.example.com\nexample.com\ninternal.example.com\n"
end
```

Initially mark the compiler test with the smallest encoded supported input; Task
5 replaces the temporary decoder clause with the full GFWList parser.

- [ ] **Step 2: Verify RED**

Run renderer/compiler tests and expect undefined modules.

- [ ] **Step 3: Implement output and snapshot structs**

```elixir
defmodule GSMLG.ProxyRules.Output do
  @enforce_keys [:body, :sha256, :etag, :last_modified, :content_type, :content_length]
  defstruct @enforce_keys

  def new(body, compiled_at) do
    sha256 = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    %__MODULE__{
      body: body,
      sha256: sha256,
      etag: ~s("sha256-#{sha256}"),
      last_modified: compiled_at,
      content_type: "text/plain; charset=utf-8",
      content_length: byte_size(body)
    }
  end
end
```

`Snapshot` contains generation, compiled_at, readiness, source_versions,
rendered_outputs, statistics, diagnostics, and last_error. Add
`Snapshot.metadata/1` that removes bodies while retaining artifact metadata.

- [ ] **Step 4: Implement renderers and compiler orchestration**

`Renderer.render/2` maps the deterministic rule list to format-specific lines
and uses `Enum.intersperse/2` plus `IO.iodata_to_binary/1`; it does not repeatedly
concatenate binaries.

`Compiler.compile/2` parses remote and local inputs, partitions actions, invokes
`Hierarchy.fold_with_stats/1` independently, computes conflict domains with
`MapSet.intersection/2`, renders all six outputs, and returns
`{:ok, %Snapshot{readiness: :ready}}`. It returns `{:error, diagnostics}` for
systemic source-shape or decode failures.

- [ ] **Step 5: Add determinism properties**

Generate duplicate domain inputs and assert that shuffled equivalent inputs
produce identical `rendered_outputs` and ETags. Assert adding a direct child
never changes proxy output.

- [ ] **Step 6: Verify GREEN and commit**

Run renderer/compiler/property tests, then commit:

```bash
git add apps/proxy_rules/lib/gsmlg/proxy_rules/{renderer,output,snapshot,compiler}.ex apps/proxy_rules/test/gsmlg/proxy_rules/{renderer,compiler*}_test.exs
git commit -m "feat(proxy-rules): render immutable artifacts"
```

### Task 5: Decode and Safely Parse GFWList

**Files:**

- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/parser/gfwlist.ex`
- Create: `apps/proxy_rules/test/gsmlg/proxy_rules/parser/gfwlist_test.exs`
- Create: `apps/proxy_rules/test/fixtures/gfwlist/official.txt`
- Create: `apps/proxy_rules/test/fixtures/gfwlist/supported.txt`
- Create: `apps/proxy_rules/test/fixtures/gfwlist/README.md`
- Modify: `apps/proxy_rules/lib/gsmlg/proxy_rules/compiler.ex`
- Modify: `apps/proxy_rules/test/gsmlg/proxy_rules/compiler_test.exs`

- [ ] **Step 1: Vendor and attribute the official fixture**

Run exactly once from the feature worktree:

```bash
curl --fail --location --silent --show-error \
  https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt \
  --output apps/proxy_rules/test/fixtures/gfwlist/official.txt
sha256sum apps/proxy_rules/test/fixtures/gfwlist/official.txt
```

Record the source URL, retrieval date, SHA-256, and upstream repository license
link in the fixture README. Create `supported.txt` by Base64-encoding a small
synthetic Adblock document containing comments, metadata, proxy, exception,
path, regex, modifier, wildcard, malformed, and Unicode cases.

- [ ] **Step 2: Write classification tests**

```elixir
test "decodes whitespace-tolerant Base64 and classifies safe rules" do
  encoded = Base.encode64("[Adblock Plus 2.0]\n! comment\n||example.com^\n@@||direct.example.com^\n")
  spaced = encoded |> String.graphemes() |> Enum.chunk_every(16) |> Enum.join("\n")

  assert {:ok, result, metadata} = GFWList.parse(spaced, 10)
  assert Enum.map(result.rules, &{&1.action, &1.domain.name}) == [proxy: "example.com", direct: "direct.example.com"]
  assert metadata.decoded_sha256 =~ ~r/^[0-9a-f]{64}$/
end

test "never broadens path, regex, modifier, or wildcard rules" do
  source = "||example.com/path\n/example\\.com/\n||example.com^$script\n||*.example.com^\n"
  assert {:ok, %ParseResult{rules: [], counts: %{unsupported: 4}}, _} = GFWList.parse(Base.encode64(source), 2)
end

test "the attributed official fixture is valid" do
  fixture = File.read!(fixture_path("official.txt"))
  assert {:ok, %ParseResult{counts: %{accepted: accepted}}, _} = GFWList.parse(fixture, 20)
  assert accepted > 1_000
end
```

- [ ] **Step 3: Verify RED**

Run the GFWList tests and expect undefined `Parser.GFWList`.

- [ ] **Step 4: Implement decode, classify, and safe extraction**

Expose:

```elixir
@spec decode(binary()) :: {:ok, binary()} | {:error, :invalid_base64 | :invalid_utf8}
def decode(body) do
  compact = String.replace(body, ~r/\s+/u, "")

  with {:ok, decoded} <- Base.decode64(compact, ignore: :whitespace),
       true <- String.valid?(decoded) do
    {:ok, decoded}
  else
    :error -> {:error, :invalid_base64}
    false -> {:error, :invalid_utf8}
  end
end
```

Classify before extraction. Accept only domain anchors, exceptions, plain
domains, and whole-host HTTP/HTTPS rules. Reject slash-delimited regular
expressions, `$` modifiers, `*`, and any URL with path/query/fragment as unsupported. Pass candidates through
`Domain.normalize/1`; normalization failures are invalid. Preserve complete
counts and bounded diagnostic samples.

- [ ] **Step 5: Integrate the parser into Compiler**

Replace the temporary decoder in Task 4 with `GFWList.parse/2`. Merge its proxy
and direct rules with the corresponding local parser results. Put decoded
content hash and input counts into `source_versions` and `statistics`.

- [ ] **Step 6: Verify GREEN and commit**

Run GFWList and compiler tests, then:

```bash
git add apps/proxy_rules/lib/gsmlg/proxy_rules/parser/gfwlist.ex apps/proxy_rules/lib/gsmlg/proxy_rules/compiler.ex apps/proxy_rules/test/gsmlg/proxy_rules/parser/gfwlist_test.exs apps/proxy_rules/test/gsmlg/proxy_rules/compiler_test.exs apps/proxy_rules/test/fixtures/gfwlist
git commit -m "feat(proxy-rules): parse official gfwlist rules"
```

### Task 6: Persist and Atomically Publish Last-Known-Good Artifacts

**Files:**

- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/persistence.ex`
- Modify: `apps/proxy_rules/lib/gsmlg/proxy_rules/store.ex`
- Create: `apps/proxy_rules/test/gsmlg/proxy_rules/persistence_test.exs`
- Modify: `apps/proxy_rules/test/gsmlg/proxy_rules/store_test.exs`

- [ ] **Step 1: Write persistence and Store tests**

```elixir
@tag :tmp_dir
test "round-trips a versioned checksummed artifact atomically", %{tmp_dir: dir} do
  snapshot = fixture_snapshot(4)
  assert :ok = Persistence.write_artifact(dir, snapshot)
  assert {:ok, ^snapshot} = Persistence.read_artifact(dir)
  refute Path.wildcard(Path.join(dir, ".artifact.snapshot.*.tmp")) != []
end

@tag :tmp_dir
test "rejects corrupt and incompatible envelopes", %{tmp_dir: dir} do
  File.write!(Path.join(dir, "artifact.snapshot"), "not a term")
  assert {:error, :corrupt_snapshot} = Persistence.read_artifact(dir)
end
```

```elixir
test "publishes and updates status as one complete ETS record" do
  snapshot = fixture_snapshot(9)
  assert :ok = Store.publish(snapshot)
  assert {:ok, %Snapshot{generation: 9}} = Store.current()
  assert :ok = Store.update_status(:stale, %{kind: :remote, reason: :timeout})
  assert {:ok, %Snapshot{generation: 9, readiness: :stale, last_error: %{reason: :timeout}}} = Store.current()
end
```

- [ ] **Step 2: Verify RED**

Run persistence and Store tests; expect undefined functions.

- [ ] **Step 3: Implement versioned checksum envelopes**

Use `%{type: type, version: 1, sha256: hash, payload: payload}`. Encode payload
once with `:erlang.term_to_binary/2`, hash those bytes, and store the payload
bytes in the envelope. Decode the outer and inner terms with
`:erlang.binary_to_term(binary, [:safe])`; validate type, version, checksum, and
expected struct before success.

Implement `atomic_write/2` with a unique same-directory temporary path,
`:file.open/2`, `:file.write/2`, `:file.sync/1`, `:file.close/1`, and
`File.rename/2`. Remove the explicit temporary file on expected error.

- [ ] **Step 4: Add serialized Store writes and restoration**

Add `publish/1`, `update_status/2`, and `metadata/0` as GenServer calls. Keep
`current/0` as a direct ETS read. In `init/1`, restore a valid artifact from the
configured state directory, replace readiness with `:stale`, and insert it
before returning. Missing/corrupt snapshots return an empty ready Store and an
operational diagnostic rather than crashing.

- [ ] **Step 5: Verify GREEN and commit**

Run persistence and Store tests, then:

```bash
git add apps/proxy_rules/lib/gsmlg/proxy_rules/{persistence,store}.ex apps/proxy_rules/test/gsmlg/proxy_rules/{persistence,store}_test.exs
git commit -m "feat(proxy-rules): persist last known good artifacts"
```

### Task 7: Add Bounded Telemetry Helpers and Streaming HTTP Transport

**Files:**

- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/telemetry.ex`
- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/transport.ex`
- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/transport/finch.ex`
- Create: `apps/proxy_rules/test/gsmlg/proxy_rules/telemetry_test.exs`
- Create: `apps/proxy_rules/test/gsmlg/proxy_rules/transport/finch_test.exs`

- [ ] **Step 1: Write telemetry and bounded transport tests**

Attach a temporary telemetry handler and assert:

```elixir
assert :ok = Telemetry.emit([:remote, :fetch, :stop], %{duration: 10}, %{status: 200})
assert_receive {[:gsmlg, :proxy_rules, :remote, :fetch, :stop], %{duration: 10}, %{status: 200}}
```

Start a minimal local HTTP fixture server in the transport test and assert a
small chunked response returns `{:ok, %{status: 200, headers: _, body: body}}`,
while a response larger than `max_body_size` returns
`{:error, :body_too_large}` without accumulating the rest.

- [ ] **Step 2: Verify RED**

Run both tests and expect undefined telemetry and transport modules.

- [ ] **Step 3: Implement the behavior and telemetry prefix**

```elixir
defmodule GSMLG.ProxyRules.Transport do
  @callback get(String.t(), [{String.t(), String.t()}], keyword()) ::
              {:ok, %{status: pos_integer(), headers: [{binary(), binary()}], body: binary()}}
              | {:error, term()}
end
```

```elixir
def emit(suffix, measurements, metadata) do
  :telemetry.execute([:gsmlg, :proxy_rules | suffix], measurements, metadata)
end
```

Add `sample_log/5` that calls `GSMLG.Telemetry.log/3` only when the zero-based
sample index is below the configured limit; metadata contains category, source,
and location, never the complete source body.

- [ ] **Step 4: Implement streamed Finch transport**

Build a GET request and call `Finch.stream_while/5`. The reducer records status
and headers, appends chunks as iodata, tracks total bytes, and returns
`{:halt, {:error, :body_too_large}}` immediately when the configured limit is
crossed. Normalize Finch/Mint failures to bounded reason atoms. Accept
`finch_name`, `receive_timeout`, and `max_body_size` options.

- [ ] **Step 5: Verify GREEN and commit**

Run both tests, then:

```bash
git add apps/proxy_rules/lib/gsmlg/proxy_rules/{telemetry,transport}.ex apps/proxy_rules/lib/gsmlg/proxy_rules/transport/finch.ex apps/proxy_rules/test/gsmlg/proxy_rules/{telemetry,transport}
git commit -m "feat(proxy-rules): add bounded remote transport"
```

### Task 8: Fetch, Validate, Cache, and Retry the Remote Source

**Files:**

- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/source_snapshot.ex`
- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/source/remote.ex`
- Create: `apps/proxy_rules/test/gsmlg/proxy_rules/source/remote_test.exs`
- Modify: `apps/proxy_rules/lib/gsmlg/proxy_rules/persistence.ex`
- Modify: `apps/proxy_rules/test/gsmlg/proxy_rules/persistence_test.exs`

- [ ] **Step 1: Write remote state-machine tests with an injectable transport**

Define `GSMLG.ProxyRules.TestTransport` in the test file. Its `get/3` sends the
request URL, headers, and options to the test process and receives the next
response from that process.

```elixir
test "a valid 200 persists and notifies only changed content", %{server: server, notify: notify} do
  body = Base.encode64("||example.com^\n")
  send(server, {:transport_response, {:ok, %{status: 200, headers: [{"etag", "upstream-1"}], body: body}}})

  assert {:ok, :accepted} = Remote.refresh(server)
  assert_receive {:proxy_rules_source, :remote, %SourceSnapshot{content_sha256: hash}}
  assert hash == sha256("||example.com^\n")

  send(server, {:transport_response, {:ok, %{status: 200, headers: [{"etag", "upstream-2"}], body: body}}})
  assert {:ok, :accepted} = Remote.refresh(server)
  refute_receive {:proxy_rules_source, :remote, _}, 100
  assert_receive {:proxy_rules_source_fresh, :remote, %{etag: "upstream-2"}}
end
```

Add tests for validator headers, `304`, invalid Base64, oversized body, timeout,
manual-refresh coalescing, exponential bounds, jitter-disabled exact delays,
and restored cached source after an offline start.

- [ ] **Step 2: Verify RED**

Run `source/remote_test.exs`; expect undefined modules.

- [ ] **Step 3: Define source snapshots and remote persistence**

```elixir
defmodule GSMLG.ProxyRules.SourceSnapshot do
  @enforce_keys [:kind, :content, :content_sha256, :observed_at]
  defstruct [:kind, :content, :content_sha256, :observed_at, metadata: %{}, availability: :ready]
end
```

Extend Persistence with `write_remote/3` and `read_remote/1`. Store the original
Base64 body in `remote.body`; store a typed metadata envelope in
`remote.metadata` containing URL, validators, fetched time, and body checksum.
Restore validates the metadata envelope, raw body checksum, Base64, UTF-8, and
decoded hash before returning a `SourceSnapshot`.

- [ ] **Step 4: Implement non-blocking fetch orchestration**

`Remote.refresh/1` is a GenServer call. When idle it starts a
`Task.Supervisor.async_nolink/2` transport task, stores the monitor reference,
emits fetch-start telemetry, and replies `{:ok, :accepted}`. When already active
it replies accepted without starting another task.

Handle task results by:

1. Validating status.
2. Decoding with `Parser.GFWList.decode/1`.
3. Computing original and decoded hashes.
4. Atomically persisting the raw body and metadata.
5. Notifying the Coordinator only if decoded content changed.
6. Sending a freshness-only notification for `304` or identical content.
7. Resetting retry state and scheduling the normal interval.

Failures retain the prior source, emit bounded status, and schedule
`min(retry_min_interval * 2^attempt, retry_max_interval)`, applying uniform
jitter only when enabled. Store timer refs and cancel superseded timers.

- [ ] **Step 5: Verify GREEN and commit**

Run remote and persistence tests, then:

```bash
git add apps/proxy_rules/lib/gsmlg/proxy_rules/{source_snapshot,persistence}.ex apps/proxy_rules/lib/gsmlg/proxy_rules/source/remote.ex apps/proxy_rules/test/gsmlg/proxy_rules/{source,persistence_test.exs}
git commit -m "feat(proxy-rules): ingest remote gfwlist source"
```

### Task 9: Watch and Reconcile Local Source Files

**Files:**

- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/source/local.ex`
- Create: `apps/proxy_rules/test/gsmlg/proxy_rules/source/local_test.exs`

- [ ] **Step 1: Write temporary-directory integration tests**

```elixir
@tag :tmp_dir
test "missing initial files are empty and later creation notifies", %{tmp_dir: dir} do
  proxy = Path.join(dir, "proxy.txt")
  direct = Path.join(dir, "direct.txt")
  {:ok, server} = start_local(proxy, direct, self())

  assert %{proxy: %SourceSnapshot{content: ""}, direct: %SourceSnapshot{content: ""}} =
           Local.snapshots(server)

  File.write!(proxy, "example.com\n")
  assert :ok = Local.reconcile(server)
  assert_receive {:proxy_rules_source, :local_proxy, %SourceSnapshot{content: "example.com\n"}}
end
```

Add tests for in-place edits, atomic rename, symlink target replacement,
comment/line-ending normalization, debounce coalescing, unchanged hashes,
periodic reconciliation, invalid replacement retaining the prior snapshot, and
temporary disappearance after a valid file.

- [ ] **Step 2: Verify RED**

Run `source/local_test.exs`; expect undefined `Source.Local`.

- [ ] **Step 3: Implement normalized reads and reconciliation**

Create `Local.start_link/1`, `snapshots/1`, and `reconcile/1`. Normalize CRLF to
LF, trim trailing horizontal whitespace per line, and ensure a non-empty source
has one final newline. Parse with `Parser.Local` before accepting a replacement.
A genuinely empty or comment-only file is valid. When a non-comment file has
zero accepted rules and one or more invalid lines, treat it as an invalid
replacement and retain the previous snapshot. On first `:enoent`, accept empty
content; after a valid snapshot, retain it on missing/read/parse failure.

For each changed content hash, send:

```elixir
send(notify, {:proxy_rules_source, source_kind, snapshot})
```

For unchanged successful reads, send one freshness message only when
availability changes back to ready.

- [ ] **Step 4: Add directory watching, debounce, and reconciliation timers**

In `handle_continue/2`, start one FileSystem watcher for the unique containing
directories and subscribe the Local process. Any relevant file event cancels
and resets the debounce timer. `:debounced_reconcile` reads both paths. A
separate periodic timer always reschedules after `:periodic_reconcile`.
Treat watcher exit as an unexpected linked failure so Local restarts.

- [ ] **Step 5: Verify GREEN and commit**

Run the local source test repeatedly to expose timing flakes:

```bash
devenv shell -- unbuffer mix test apps/proxy_rules/test/gsmlg/proxy_rules/source/local_test.exs --repeat-until-failure 5
git add apps/proxy_rules/lib/gsmlg/proxy_rules/source/local.ex apps/proxy_rules/test/gsmlg/proxy_rules/source/local_test.exs
git commit -m "feat(proxy-rules): watch local rule sources"
```

### Task 10: Coordinate Generations and Complete the Supervision Tree

**Files:**

- Modify: `apps/proxy_rules/lib/gsmlg/proxy_rules/coordinator.ex`
- Modify: `apps/proxy_rules/lib/gsmlg/proxy_rules/supervisor.ex`
- Modify: `apps/proxy_rules/lib/gsmlg/proxy_rules/application.ex`
- Modify: `apps/proxy_rules/lib/gsmlg/proxy_rules.ex`
- Modify: `apps/proxy_rules/test/gsmlg/proxy_rules/application_test.exs`
- Modify: `apps/proxy_rules/test/gsmlg/proxy_rules_test.exs`
- Create: `apps/proxy_rules/test/gsmlg/proxy_rules/coordinator_test.exs`
- Create: `apps/proxy_rules/test/gsmlg/proxy_rules/publication_concurrency_test.exs`

- [ ] **Step 1: Write generation and facade tests**

```elixir
test "publishes only the latest generation after persistence" do
  coordinator = start_coordinator(compiler: ControlledCompiler, persistence: TestPersistence)
  send_sources(coordinator, generation_inputs("one.example"))
  assert_receive {:compile_started, 1, first_task}

  send(coordinator, source_message(:local_proxy, "two.example\n"))
  send(first_task, {:finish, {:ok, snapshot(1)}})
  refute_receive {:published, 1}
  assert_receive {:compile_started, 2, second_task}
  send(second_task, {:finish, {:ok, snapshot(2)}})
  assert_receive {:persisted, 2}
  assert_receive {:published, 2}
end

test "failed compile and failed persistence keep the current artifact" do
  coordinator = start_coordinator(compiler: ControlledCompiler, persistence: TestPersistence)
  seed_published_generation(coordinator, snapshot(1))

  send_sources(coordinator, generation_inputs("compile-fails.example"))
  assert_receive {:compile_started, 2, compile_task}
  send(compile_task, {:finish, {:error, [%Diagnostic{kind: :invalid, reason: :systemic_failure}]}})
  assert_eventually(fn -> Store.current() end, {:ok, %Snapshot{generation: 1, readiness: :stale}})

  send_sources(coordinator, generation_inputs("persist-fails.example"))
  assert_receive {:compile_started, 3, persist_task}
  send(TestPersistence, {:fail_next, :permission_denied})
  send(persist_task, {:finish, {:ok, snapshot(3)}})
  assert_eventually(fn -> Store.current() end, {:ok, %Snapshot{generation: 1, readiness: :stale}})
end
```

Facade tests must now assert:

```elixir
assert {:ok, %{readiness: :not_ready}} = ProxyRules.metadata()
assert {:ok, :accepted} = ProxyRules.refresh()
assert {:ok, %Output{}} = ProxyRules.get_artifact(:proxy, :raw)
```

The concurrency test loops publication across at least 100 generations while
reader tasks assert every returned snapshot has six outputs all bearing the
same generation metadata.

- [ ] **Step 2: Verify RED**

Run Coordinator, facade, application, and concurrency tests; expect the current
Milestone 1 behavior to fail.

- [ ] **Step 3: Implement authoritative generation state**

Coordinator state contains remote, local_proxy, local_direct, source_generation,
active task/ref/generation, pending flag, and last failure. It handles source
content and freshness messages, compares all restored artifact source hashes,
and compiles only after remote is valid.

Start compilation with `Task.Supervisor.async_nolink/2`. On completion:

- Discard a result whose generation is no longer current.
- Persist a current successful result before `Store.publish/1`.
- Mark Store stale on compile, task, or persistence failure.
- Start exactly one latest pending generation after the active task exits.
- Emit compilation, stale-discard, publication, and status telemetry.

`handle_call(:refresh, _from, state)` delegates to `Source.Remote.refresh/0`; it returns
accepted separately from completion.

- [ ] **Step 4: Complete the supervisor with one configuration value**

Load `Configuration` once in `Supervisor.init/1`. Start:

```elixir
children = [
  {Task.Supervisor, name: GSMLG.ProxyRules.TaskSupervisor},
  {Finch, name: GSMLG.ProxyRules.Finch, pools: %{default: [conn_opts: [transport_opts: [timeout: config.remote_connect_timeout]]]}},
  {Store, configuration: config},
  {Source.Remote, configuration: config},
  {Source.Local, configuration: config},
  {Coordinator, configuration: config}
]
```

Update the application test to assert six active children, two supervisors, and
four workers. Source services expose current snapshots so Coordinator can query
them in `handle_continue/2` if their startup notifications occurred before it
was registered.

- [ ] **Step 5: Complete the facade**

`metadata/0` delegates to Store metadata and always returns
`{:ok, metadata}` when Store is running, including not-ready state.
`get_artifact/2` validates identifiers and reads the selected `%Output{}` from
one Store snapshot. `refresh/0` safely maps missing Coordinator/Remote processes
to `{:error, :not_available}`.

- [ ] **Step 6: Verify GREEN and commit**

Run the four scoped test files and the entire proxy_rules test directory, then:

```bash
git add apps/proxy_rules/lib/gsmlg/proxy_rules{.ex,/application.ex,/coordinator.ex,/supervisor.ex} apps/proxy_rules/test/gsmlg/proxy_rules{_test.exs,/application_test.exs,/coordinator_test.exs,/publication_concurrency_test.exs}
git commit -m "feat(proxy-rules): publish authoritative generations"
```

### Task 11: Expose the Six Public Conditional Download Endpoints

**Files:**

- Modify: `apps/gsmlg_web/mix.exs`
- Modify: `apps/gsmlg_web/lib/gsmlg/web/router.ex`
- Create: `apps/gsmlg_web/lib/gsmlg/web/controllers/proxy_rules_controller.ex`
- Create: `apps/gsmlg_web/test/gsmlg_web/controllers/proxy_rules_controller_test.exs`

- [ ] **Step 1: Write controller contract tests**

Seed a complete Store snapshot around each test and restore the prior record in
`on_exit/1`. Test all list/format pairs:

```elixir
for {list_path, list} <- [{"proxy-list", :proxy}, {"direct-list", :direct}],
    format <- ~w(raw squid clash) do
  test "serves #{list_path}/#{format} with immutable metadata", %{conn: conn} do
    conn = get(conn, "/api/proxy-rules/#{unquote(list_path)}/#{unquote(format)}")
    assert response(conn, 200) == expected_body(unquote(list), unquote(format))
    assert [etag] = get_resp_header(conn, "etag")
    assert etag =~ ~r/^"sha256-[0-9a-f]{64}"$/
    assert get_resp_header(conn, "x-proxy-rules-generation") == ["12"]
  end
end
```

Add tests for comma-separated and weak matching ETags, `*`, mismatches, invalid
identifiers returning 404, and an empty Store returning 503.

- [ ] **Step 2: Verify RED**

Run only `proxy_rules_controller_test.exs`; expect 404 from the API catch-all.

- [ ] **Step 3: Add dependency, route, and thin controller**

Add `{:proxy_rules, in_umbrella: true}` to `gsmlg_web`. Insert before the API
catch-all:

```elixir
scope "/api/proxy-rules", GSMLG.Web do
  pipe_through(:api)
  get("/:list/:format", ProxyRulesController, :show)
end
```

The controller maps only fixed strings to atoms, calls the facade once, and:

- Sends `200` with body and exact stored headers.
- Sends `304` with validators and an empty body on weak ETag match.
- Sends plain bounded `404` or `503` responses for facade errors.
- Emits API hit or conditional-hit telemetry.

Implement `If-None-Match` parsing without creating atoms: split on commas,
trim, remove an optional `W/`, and compare the quoted tags; `*` matches any
current output.

- [ ] **Step 4: Verify GREEN and commit**

Run the controller test and existing API error controller test, then:

```bash
git add apps/gsmlg_web/mix.exs apps/gsmlg_web/lib/gsmlg/web/{router.ex,controllers/proxy_rules_controller.ex} apps/gsmlg_web/test/gsmlg_web/controllers/proxy_rules_controller_test.exs
git commit -m "feat(web): serve proxy rule artifacts"
```

### Task 12: Bridge Status Events into the Admin LiveView

**Files:**

- Modify: `apps/gsmlg_admin_web/mix.exs`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/application.ex`
- Create: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/proxy_rules_telemetry_bridge.ex`
- Create: `apps/gsmlg_admin_web/test/gsmlg/admin_web/proxy_rules_telemetry_bridge_test.exs`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/proxy_rules_live/index.ex`
- Modify: `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs`

- [ ] **Step 1: Write bridge and complete LiveView tests**

```elixir
test "broadcasts only proxy-rule status events" do
  Phoenix.PubSub.subscribe(GSMLG.PubSub, ProxyRulesTelemetryBridge.topic())
  :telemetry.execute([:gsmlg, :proxy_rules, :status, :change], %{generation: 3}, %{readiness: :ready})
  assert_receive {:proxy_rules_status_changed, %{generation: 3}, %{readiness: :ready}}
end
```

LiveView tests seed metadata for each state and assert the badge, summary,
source cards, bounded diagnostics, artifact rows, and six absolute URLs built
from `GSMLG.Web.Endpoint.url/0`. Add event tests proving refresh acceptance
shows refreshing, duplicate click is disabled, rejection flashes an error, and
a PubSub status message reloads ready metadata.

- [ ] **Step 2: Verify RED**

Run bridge and LiveView tests; expect undefined bridge and static shell failures.

- [ ] **Step 3: Add the telemetry bridge**

Add an explicit `{:gsmlg_web, in_umbrella: true}` admin dependency. Implement a
GenServer that attaches one handler id to status-change, publication,
restoration, and failure events in `init/1`; the handler broadcasts a bounded
tuple to `"proxy_rules:status"`. Detach in `terminate/2`. Add the bridge child
before the Endpoint in `GSMLG.AdminWeb.Application`.

- [ ] **Step 4: Replace hard-coded shell state with facade metadata**

In `mount/3`, assign metadata through one `load_state/1` mapper and subscribe
only when `connected?(socket)`. Implement:

```elixir
def handle_event("refresh", _params, socket) do
  case GSMLG.ProxyRules.refresh() do
    {:ok, :accepted} -> {:noreply, assign(socket, state: %{socket.assigns.state | status: :refreshing})}
    {:error, reason} -> {:noreply, put_flash(socket, :error, refresh_error(reason))}
  end
end

def handle_info({:proxy_rules_status_changed, _measurements, _metadata}, socket) do
  {:noreply, assign(socket, state: load_state())}
end
```

Render DuskMoon badges for all four states, active refresh only when available,
real values or explicit unavailable text, six artifact rows, and bounded
diagnostic samples. Move the Artifacts `<h2>` outside the card title slot so the
markup has a valid heading hierarchy.

- [ ] **Step 5: Build absolute public URLs safely**

Use `GSMLG.Web.Endpoint.url/0` as the base and fixed list/format path segments.
Never derive atoms or path segments from diagnostic/source text. Display only a
short ETag but keep the full value in a `title` attribute.

- [ ] **Step 6: Verify GREEN and commit**

Run bridge, LiveView, navigation, and route tests, then:

```bash
git add apps/gsmlg_admin_web/mix.exs apps/gsmlg_admin_web/lib/gsmlg/admin_web/{application.ex,proxy_rules_telemetry_bridge.ex,live/proxy_rules_live/index.ex} apps/gsmlg_admin_web/test/gsmlg/admin_web/{proxy_rules_telemetry_bridge_test.exs,live/proxy_rules_live_test.exs}
git commit -m "feat(admin): operate proxy rules service"
```

### Task 13: Add Benchmarks, Operator Documentation, and Runtime Directories

**Files:**

- Create: `apps/proxy_rules/bench/proxy_rules_benchmark.exs`
- Create: `apps/proxy_rules/README.md`
- Modify: `Dockerfile`
- Modify: `Dockerfile.alpine`
- Modify: `Dockerfile.lite`
- Modify: `docs/deploy.md`
- Create: `apps/proxy_rules/test/gsmlg/proxy_rules/operational_test.exs`

- [ ] **Step 1: Write deployment and benchmark smoke tests**

The operational test reads all three Dockerfiles and asserts they create
`/etc/gsmlg/proxy-rules` and `/var/lib/gsmlg/proxy-rules`. It invokes the
benchmark module in a one-iteration test mode and pattern matches compile time,
artifact bytes, and lookup throughput as positive values without enforcing a
wall-clock threshold.

- [ ] **Step 2: Verify RED**

Run `operational_test.exs`; expect missing benchmark and directory declarations.

- [ ] **Step 3: Add a reproducible benchmark**

The script loads `test/fixtures/gfwlist/official.txt`, uses empty local sources,
runs the compiler for a configurable iteration count, publishes one snapshot to
a unique ETS table, times at least 100,000 direct lookups, and prints:

```text
fixture_sha256=<hex>
accepted_rules=<count>
compile_mean_ms=<number>
artifact_bytes=<number>
lookup_ops_per_second=<number>
otp_release=<number>
elixir_version=<version>
```

Expose a small pure `run/1` return map so the smoke test does not parse stdout.

- [ ] **Step 4: Document operation and prepare directories**

Document every existing config key, startup recovery, manual refresh,
ready/stale diagnosis, public URLs, ETag use, local file grammar, permissions,
and direct-before-proxy gateway order in `apps/proxy_rules/README.md`.

In all Docker runtime stages create both directories alongside the existing
Mnesia directory. Add the state directory as a volume where the Dockerfile
already declares persistent volumes. In `docs/deploy.md`, add
`ConfigurationDirectory=gsmlg/proxy-rules` and
`StateDirectory=gsmlg/proxy-rules` to the umbrella systemd example plus curl
checks for one raw endpoint and one conditional request.

- [ ] **Step 5: Verify GREEN and commit**

Run the operational test and benchmark once, then:

```bash
git add apps/proxy_rules/bench apps/proxy_rules/README.md apps/proxy_rules/test/gsmlg/proxy_rules/operational_test.exs Dockerfile Dockerfile.alpine Dockerfile.lite docs/deploy.md
git commit -m "docs(proxy-rules): add operational deployment guide"
```

### Task 14: Run Full In-Scope Verification and Harden Findings

**Files:**

- Modify only files already listed in Tasks 1-13 when a failing in-scope test proves a defect.

- [ ] **Step 1: Run all proxy_rules tests**

```bash
devenv shell -- unbuffer mix test apps/proxy_rules/test
```

Expected: all unit, property, integration, persistence, concurrency, and
operational tests pass.

- [ ] **Step 2: Run scoped web and admin tests**

```bash
devenv shell -- unbuffer mix test \
  apps/gsmlg_web/test/gsmlg_web/controllers/proxy_rules_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/api_error_controller_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/proxy_rules_telemetry_bridge_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/components/admin_navigation_test.exs
```

Expected: all scoped Phoenix tests pass.

- [ ] **Step 3: Run scoped formatting and static checks**

```bash
devenv shell -- mix format --check-formatted \
  apps/proxy_rules \
  apps/gsmlg_web/lib/gsmlg/web/controllers/proxy_rules_controller.ex \
  apps/gsmlg_web/lib/gsmlg/web/router.ex \
  apps/gsmlg_web/test/gsmlg_web/controllers/proxy_rules_controller_test.exs \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/proxy_rules_telemetry_bridge.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/proxy_rules_live/index.ex \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/proxy_rules_telemetry_bridge_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs
devenv shell -- unbuffer mix credo --strict apps/proxy_rules
git diff --check
```

Expected: all commands exit 0.

- [ ] **Step 4: Run umbrella finish gates**

```bash
devenv shell -- unbuffer mix compile --warnings-as-errors
MIX_ENV=prod devenv shell -- unbuffer mix release gsmlg_umbrella --overwrite
```

Expected: exit 0. If either reaches a previously recorded unrelated failure,
capture the exact file and error and do not modify it.

- [ ] **Step 5: Perform live runtime smoke verification**

Start the release or development process with temporary proxy-rules config and
state paths. Verify:

```bash
curl --fail --show-error --dump-header /tmp/proxy-rules.headers http://127.0.0.1:4110/api/proxy-rules/proxy-list/raw --output /tmp/proxy-list.raw
etag=$(awk 'BEGIN {IGNORECASE=1} /^etag:/ {sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print}' /tmp/proxy-rules.headers)
curl --silent --output /dev/null --write-out '%{http_code}\n' -H "If-None-Match: $etag" http://127.0.0.1:4110/api/proxy-rules/proxy-list/raw
```

Expected: first request is 200 with a non-empty normalized list; second prints
`304`. Open authenticated `/proxy-rules`, trigger refresh once, and verify the
page returns to ready without losing download links.

- [ ] **Step 6: Commit only evidence-driven hardening**

If in-scope verification required changes, rerun the failing command and commit:

```bash
git add apps/proxy_rules \
  apps/gsmlg_web/lib/gsmlg/web/controllers/proxy_rules_controller.ex \
  apps/gsmlg_web/lib/gsmlg/web/router.ex \
  apps/gsmlg_web/test/gsmlg_web/controllers/proxy_rules_controller_test.exs \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/proxy_rules_telemetry_bridge.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/proxy_rules_live/index.ex \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/proxy_rules_telemetry_bridge_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs
git commit -m "fix(proxy-rules): harden full v1 pipeline"
```

If no changes were required, do not create an empty commit.

## Completion Gate

Before declaring completion, confirm:

- Every task commit passed specification-compliance and code-quality review.
- `git status --short` is clean.
- All six public endpoints and conditional requests work.
- Offline restart serves the persisted last-known-good artifact as stale.
- A failed manual refresh retains the current generation and download links.
- The final report distinguishes in-scope passes from unchanged unrelated
  repository blockers.
