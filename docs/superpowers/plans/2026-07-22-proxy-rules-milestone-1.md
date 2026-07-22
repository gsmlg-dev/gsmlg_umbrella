# Proxy Rules Milestone 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `:proxy_rules` OTP application, validated runtime defaults, release wiring, and an authenticated `gsmlg_admin_web` dashboard that accurately renders the pre-compilation state.

**Architecture:** `GSMLG.ProxyRules` is a Phoenix-independent facade backed by a protected ETS table owned by `GSMLG.ProxyRules.Store`; reads bypass the Store GenServer, while refresh requests serialize through `GSMLG.ProxyRules.Coordinator`. `gsmlg_admin_web` depends on the new app and reads only the facade. Milestone 1 publishes no artifacts and performs no network or filesystem work, so the dashboard renders explicit unavailable values and a disabled refresh control.

**Tech Stack:** Elixir 1.18, OTP 28, ETS, Phoenix LiveView, Phoenix DuskMoon, NimbleOptions, TOML, ExUnit.

---

## Scope Boundary

This plan implements only Milestone 1 plus the approved admin-dashboard shell.
It does not implement remote fetching, local watchers, Base64 decoding, parsing,
normalization, compilation, rendering, publication, persistence, telemetry,
public download endpoints, or active refresh. Do not add modules for those later
milestones.

## File Map

Create the OTP application:

- `apps/proxy_rules/mix.exs` — umbrella child project definition.
- `apps/proxy_rules/lib/gsmlg/proxy_rules.ex` — stable public facade.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/application.ex` — OTP application callback.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/supervisor.ex` — fixed `:one_for_one` tree.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/store.ex` — protected ETS owner and direct readers.
- `apps/proxy_rules/lib/gsmlg/proxy_rules/coordinator.ex` — serialized refresh boundary.
- `apps/proxy_rules/test/test_helper.exs` — ExUnit startup.
- `apps/proxy_rules/test/gsmlg/proxy_rules/application_test.exs` — supervision contract.
- `apps/proxy_rules/test/gsmlg/proxy_rules/store_test.exs` — safe empty-store contract.
- `apps/proxy_rules/test/gsmlg/proxy_rules_test.exs` — facade contract.

Modify runtime configuration:

- `apps/gsmlg_config/lib/gsmlg/config/schema.ex` — proxy-rules schema and defaults.
- `apps/gsmlg_config/lib/gsmlg/config/setup.ex` — apply validated settings.
- `apps/gsmlg_config/test/gsmlg/config/schema_test.exs` — schema and TOML coverage.
- `apps/gsmlg_config/test/gsmlg/config/setup_test.exs` — application-environment coverage.
- `apps/gsmlg_config/priv/gsmlg.toml` — fallback settings.
- `apps/gsmlg_config/priv/gsmlg.dev.toml` — development settings.
- `apps/gsmlg_config/priv/gsmlg.test.toml` — test settings.
- `apps/gsmlg_config/priv/gsmlg.prod.toml` — production settings.

Modify release and admin integration:

- `mix.exs` — start `:proxy_rules` permanently in both umbrella releases.
- `apps/gsmlg_admin_web/mix.exs` — declare the direct umbrella dependency.
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/admin_menu.ex` — Service navigation group.
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/router.ex` — authenticated LiveView route.
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/proxy_rules_live/index.ex` — dashboard shell.
- `apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs` — menu and route tests.
- `apps/gsmlg_admin_web/test/gsmlg/admin_web/components/admin_navigation_test.exs` — rendered navigation test.
- `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs` — auth and empty-state tests.

## Fixed Milestone 1 Contracts

```elixir
GSMLG.ProxyRules.get_artifact(:proxy, :raw)
# => {:error, :not_ready}

GSMLG.ProxyRules.get_artifact(:unknown, :raw)
# => {:error, :not_found}

GSMLG.ProxyRules.metadata()
# => {:error, :not_ready}

GSMLG.ProxyRules.refresh()
# => {:error, :not_available}
```

The ETS table is `:gsmlg_proxy_rules_store`. A future publication replaces one
record shaped as `{:current, snapshot}`. Milestone 1 does not expose a write API.

### Task 1: Scaffold the Umbrella Child Application

**Files:**

- Create: `apps/proxy_rules/mix.exs`
- Create: `apps/proxy_rules/test/test_helper.exs`

- [ ] **Step 1: Create the child Mix project**

```elixir
defmodule GSMLG.ProxyRules.MixProject do
  use Mix.Project

  def project do
    [
      app: :proxy_rules,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {GSMLG.ProxyRules.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
```

- [ ] **Step 2: Create the test helper**

```elixir
ExUnit.start()
```

- [ ] **Step 3: Verify Mix discovers the child app**

Run:

```bash
devenv shell -- mix cmd --app proxy_rules mix help test
```

Expected: exit 0 and Mix test help. The app itself does not compile yet because
the configured application callback is intentionally absent until Task 2.

- [ ] **Step 4: Commit the scaffold**

```bash
git add apps/proxy_rules/mix.exs apps/proxy_rules/test/test_helper.exs
git commit -m "chore(proxy-rules): scaffold umbrella application"
```

### Task 2: Start the Fixed Supervision Tree

**Files:**

- Create: `apps/proxy_rules/test/gsmlg/proxy_rules/application_test.exs`
- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/application.ex`
- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/supervisor.ex`
- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/store.ex`
- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules/coordinator.ex`

- [ ] **Step 1: Write the failing supervision test**

```elixir
defmodule GSMLG.ProxyRules.ApplicationTest do
  use ExUnit.Case, async: false

  test "starts the fixed one-for-one supervision tree" do
    assert is_pid(Process.whereis(GSMLG.ProxyRules.Supervisor))
    assert is_pid(Process.whereis(GSMLG.ProxyRules.TaskSupervisor))
    assert is_pid(Process.whereis(GSMLG.ProxyRules.Store))
    assert is_pid(Process.whereis(GSMLG.ProxyRules.Coordinator))

    assert %{active: 3, specs: 3, supervisors: 1, workers: 2} =
             Supervisor.count_children(GSMLG.ProxyRules.Supervisor)
  end
end
```

- [ ] **Step 2: Run the test and verify RED**

```bash
devenv shell -- mix test apps/proxy_rules/test/gsmlg/proxy_rules/application_test.exs
```

Expected: compilation fails because `GSMLG.ProxyRules.Application` is missing.

- [ ] **Step 3: Add the application and supervisor**

```elixir
defmodule GSMLG.ProxyRules.Application do
  use Application

  @impl true
  def start(_type, _args), do: GSMLG.ProxyRules.Supervisor.start_link([])
end
```

```elixir
defmodule GSMLG.ProxyRules.Supervisor do
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Task.Supervisor, name: GSMLG.ProxyRules.TaskSupervisor},
      GSMLG.ProxyRules.Store,
      GSMLG.ProxyRules.Coordinator
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

- [ ] **Step 4: Add the minimum startable Store**

```elixir
defmodule GSMLG.ProxyRules.Store do
  use GenServer

  @table :gsmlg_proxy_rules_store

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{}}
  end
end
```

- [ ] **Step 5: Add the minimum startable Coordinator**

```elixir
defmodule GSMLG.ProxyRules.Coordinator do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{}}
end
```

- [ ] **Step 6: Run the test and verify GREEN**

```bash
devenv shell -- mix test apps/proxy_rules/test/gsmlg/proxy_rules/application_test.exs
```

Expected: 1 test, 0 failures.

- [ ] **Step 7: Commit the supervision tree**

```bash
git add apps/proxy_rules/lib apps/proxy_rules/test/gsmlg/proxy_rules/application_test.exs
git commit -m "feat(proxy-rules): add supervision tree"
```

### Task 3: Define Safe Store and Public Facade Reads

**Files:**

- Create: `apps/proxy_rules/test/gsmlg/proxy_rules/store_test.exs`
- Create: `apps/proxy_rules/test/gsmlg/proxy_rules_test.exs`
- Modify: `apps/proxy_rules/lib/gsmlg/proxy_rules/store.ex`
- Modify: `apps/proxy_rules/lib/gsmlg/proxy_rules/coordinator.ex`
- Create: `apps/proxy_rules/lib/gsmlg/proxy_rules.ex`

- [ ] **Step 1: Write the failing Store test**

```elixir
defmodule GSMLG.ProxyRules.StoreTest do
  use ExUnit.Case, async: false

  alias GSMLG.ProxyRules.Store

  test "is protected and safe to read before publication" do
    assert :protected == :ets.info(:gsmlg_proxy_rules_store, :protection)
    assert true == :ets.info(:gsmlg_proxy_rules_store, :read_concurrency)
    assert [] == :ets.lookup(:gsmlg_proxy_rules_store, :current)
    assert {:error, :not_ready} == Store.current()
  end
end
```

- [ ] **Step 2: Run the Store test and verify RED**

```bash
devenv shell -- mix test apps/proxy_rules/test/gsmlg/proxy_rules/store_test.exs
```

Expected: compilation fails because `Store.current/0` is undefined.

- [ ] **Step 3: Implement the direct Store reader**

Add to `GSMLG.ProxyRules.Store`:

```elixir
@spec current() :: {:ok, map()} | {:error, :not_ready}
def current do
  case :ets.lookup(@table, :current) do
    [{:current, snapshot}] when is_map(snapshot) -> {:ok, snapshot}
    [] -> {:error, :not_ready}
  end
rescue
  ArgumentError -> {:error, :not_ready}
end
```

- [ ] **Step 4: Run the Store test and verify GREEN**

```bash
devenv shell -- mix test apps/proxy_rules/test/gsmlg/proxy_rules/store_test.exs
```

Expected: 1 test, 0 failures.

- [ ] **Step 5: Write the failing facade tests**

```elixir
defmodule GSMLG.ProxyRulesTest do
  use ExUnit.Case, async: false

  alias GSMLG.ProxyRules

  test "returns not-ready for every valid artifact lookup before publication" do
    for list <- [:proxy, :direct], format <- [:raw, :squid, :clash] do
      assert {:error, :not_ready} == ProxyRules.get_artifact(list, format)
    end
  end

  test "rejects unsupported list and renderer identifiers" do
    assert {:error, :not_found} == ProxyRules.get_artifact(:unknown, :raw)
    assert {:error, :not_found} == ProxyRules.get_artifact(:proxy, :unknown)
  end

  test "reports not-ready metadata without fabricated counts" do
    assert {:error, :not_ready} == ProxyRules.metadata()
  end

  test "reports refresh unavailable before source ingestion exists" do
    assert {:error, :not_available} == ProxyRules.refresh()
  end
end
```

- [ ] **Step 6: Run the facade tests and verify RED**

```bash
devenv shell -- mix test apps/proxy_rules/test/gsmlg/proxy_rules_test.exs
```

Expected: compilation fails because `GSMLG.ProxyRules` is missing.

- [ ] **Step 7: Implement the stable facade**

```elixir
defmodule GSMLG.ProxyRules do
  alias GSMLG.ProxyRules.{Coordinator, Store}

  @type list_name :: :proxy | :direct
  @type renderer :: :raw | :squid | :clash

  @spec get_artifact(list_name(), renderer()) ::
          {:ok, map()} | {:error, :not_ready | :not_found}
  def get_artifact(list, renderer)
      when list in [:proxy, :direct] and renderer in [:raw, :squid, :clash] do
    with {:ok, %{rendered_outputs: outputs}} <- Store.current(),
         {:ok, list_outputs} <- Map.fetch(outputs, list),
         {:ok, artifact} <- Map.fetch(list_outputs, renderer) do
      {:ok, artifact}
    else
      {:error, :not_ready} = error -> error
      :error -> {:error, :not_found}
    end
  end

  def get_artifact(_list, _renderer), do: {:error, :not_found}

  @spec metadata() :: {:ok, map()} | {:error, :not_ready}
  def metadata do
    with {:ok, snapshot} <- Store.current() do
      {:ok,
       Map.take(snapshot, [
         :generation,
         :compiled_at,
         :source_versions,
         :statistics,
         :diagnostics
       ])}
    end
  end

  @spec refresh() :: {:ok, :accepted} | {:error, :not_available}
  def refresh, do: Coordinator.refresh()
end
```

Add to `GSMLG.ProxyRules.Coordinator`:

```elixir
def refresh, do: GenServer.call(__MODULE__, :refresh)

@impl true
def handle_call(:refresh, _from, state), do: {:reply, {:error, :not_available}, state}
```

- [ ] **Step 8: Run all proxy-rules tests and verify GREEN**

```bash
devenv shell -- mix test apps/proxy_rules/test
```

Expected: 6 tests, 0 failures.

- [ ] **Step 9: Commit Store and facade behavior**

```bash
git add apps/proxy_rules
git commit -m "feat(proxy-rules): define not-ready public API"
```

### Task 4: Register Runtime Configuration

**Files:**

- Create: `apps/gsmlg_config/test/gsmlg/config/schema_test.exs`
- Modify: `apps/gsmlg_config/test/gsmlg/config/setup_test.exs`
- Modify: `apps/gsmlg_config/lib/gsmlg/config/schema.ex`
- Modify: `apps/gsmlg_config/lib/gsmlg/config/setup.ex`
- Modify: `apps/gsmlg_config/priv/gsmlg.toml`
- Modify: `apps/gsmlg_config/priv/gsmlg.dev.toml`
- Modify: `apps/gsmlg_config/priv/gsmlg.test.toml`
- Modify: `apps/gsmlg_config/priv/gsmlg.prod.toml`

- [ ] **Step 1: Write schema and source-file tests**

Create `schema_test.exs` as:

```elixir
defmodule GSMLG.Config.SchemaTest do
  use ExUnit.Case, async: true

  alias GSMLG.Config.Schema

  @expected %{
    source_url: "https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt",
    remote_refresh_interval: 86_400_000,
    remote_connect_timeout: 5_000,
    remote_receive_timeout: 30_000,
    remote_max_body_size: 10_000_000,
    retry_min_interval: 5_000,
    retry_max_interval: 300_000,
    retry_jitter: true,
    local_proxy_list_path: "/etc/gsmlg/proxy-rules/proxy-list.txt",
    local_direct_list_path: "/etc/gsmlg/proxy-rules/direct-list.txt",
    local_watch_debounce: 500,
    local_reconciliation_interval: 60_000,
    state_directory: "/var/lib/gsmlg/proxy-rules",
    cache_control: "public, max-age=3600",
    unsupported_rule_sample_limit: 20
  }

  test "validates proxy-rules defaults" do
    assert {:ok, %{proxy_rules: settings}} = Schema.validate(%{proxy_rules: %{}})
    assert settings == @expected
  end

  test "rejects invalid proxy-rules scheduling values" do
    assert {:error, reason} =
             Schema.validate(%{proxy_rules: %{remote_refresh_interval: 0}})

    assert reason =~ "proxy_rules"
    assert reason =~ "positive integer"
  end

  test "all active source TOML files contain proxy-rules settings" do
    config_dir = Path.expand("../../../priv", __DIR__)

    for filename <- ~w(gsmlg.toml gsmlg.dev.toml gsmlg.test.toml gsmlg.prod.toml) do
      {:ok, config} = Toml.decode_file(Path.join(config_dir, filename), keys: :atoms)
      assert config.proxy_rules == @expected
    end
  end
end
```

- [ ] **Step 2: Run schema tests and verify RED**

```bash
devenv shell -- mix test apps/gsmlg_config/test/gsmlg/config/schema_test.exs
```

Expected: defaults are absent, zero is accepted, and the TOML sections are absent.

- [ ] **Step 3: Add the complete schema**

Add this complete schema to `schema.ex`:

```elixir
@proxy_rules_schema [
  source_url: [
    type: :string,
    default: "https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt",
    doc: "Remote GFWList source URL"
  ],
  remote_refresh_interval: [
    type: :pos_integer,
    default: 86_400_000,
    doc: "Remote refresh interval in milliseconds"
  ],
  remote_connect_timeout: [
    type: :pos_integer,
    default: 5_000,
    doc: "Remote connection timeout in milliseconds"
  ],
  remote_receive_timeout: [
    type: :pos_integer,
    default: 30_000,
    doc: "Remote response timeout in milliseconds"
  ],
  remote_max_body_size: [
    type: :pos_integer,
    default: 10_000_000,
    doc: "Maximum remote response body size in bytes"
  ],
  retry_min_interval: [
    type: :pos_integer,
    default: 5_000,
    doc: "Minimum retry interval in milliseconds"
  ],
  retry_max_interval: [
    type: :pos_integer,
    default: 300_000,
    doc: "Maximum retry interval in milliseconds"
  ],
  retry_jitter: [
    type: :boolean,
    default: true,
    doc: "Apply jitter to retry intervals"
  ],
  local_proxy_list_path: [
    type: :string,
    default: "/etc/gsmlg/proxy-rules/proxy-list.txt",
    doc: "Local proxy-list source path"
  ],
  local_direct_list_path: [
    type: :string,
    default: "/etc/gsmlg/proxy-rules/direct-list.txt",
    doc: "Local direct-list source path"
  ],
  local_watch_debounce: [
    type: :pos_integer,
    default: 500,
    doc: "Local file watcher debounce in milliseconds"
  ],
  local_reconciliation_interval: [
    type: :pos_integer,
    default: 60_000,
    doc: "Local source reconciliation interval in milliseconds"
  ],
  state_directory: [
    type: :string,
    default: "/var/lib/gsmlg/proxy-rules",
    doc: "Last-known-good state directory"
  ],
  cache_control: [
    type: :string,
    default: "public, max-age=3600",
    doc: "Cache-Control value for generated artifacts"
  ],
  unsupported_rule_sample_limit: [
    type: :non_neg_integer,
    default: 20,
    doc: "Maximum unsupported-rule diagnostic samples"
  ]
]
```

Add `proxy_rules: @proxy_rules_schema` to `schema/0` and add:

```elixir
defp get_section_schema(:proxy_rules), do: @proxy_rules_schema
```

- [ ] **Step 4: Add the section to all four active TOML files**

```toml
[proxy_rules]
source_url = "https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt"
remote_refresh_interval = 86400000
remote_connect_timeout = 5000
remote_receive_timeout = 30000
remote_max_body_size = 10000000
retry_min_interval = 5000
retry_max_interval = 300000
retry_jitter = true
local_proxy_list_path = "/etc/gsmlg/proxy-rules/proxy-list.txt"
local_direct_list_path = "/etc/gsmlg/proxy-rules/direct-list.txt"
local_watch_debounce = 500
local_reconciliation_interval = 60000
state_directory = "/var/lib/gsmlg/proxy-rules"
cache_control = "public, max-age=3600"
unsupported_rule_sample_limit = 20
```

- [ ] **Step 5: Re-run schema tests and verify GREEN**

```bash
devenv shell -- mix test apps/gsmlg_config/test/gsmlg/config/schema_test.exs
```

Expected: 3 tests, 0 failures.

- [ ] **Step 6: Write the failing Setup test**

In the test module's existing `setup/1`, capture:

```elixir
proxy_rules_settings = Application.fetch_env(:proxy_rules, :settings)
```

Add this exact cleanup inside its `on_exit/1` callback:

```elixir
case proxy_rules_settings do
  {:ok, settings} -> Application.put_env(:proxy_rules, :settings, settings)
  :error -> Application.delete_env(:proxy_rules, :settings)
end
```

Then add:

```elixir
test "configures proxy-rules settings when proxy-rules config is present" do
  settings = %{
    source_url: "https://example.test/gfwlist.txt",
    remote_refresh_interval: 60_000,
    local_proxy_list_path: "/tmp/proxy-list.txt",
    local_direct_list_path: "/tmp/direct-list.txt",
    state_directory: "/tmp/proxy-rules"
  }

  GSMLG.Config.Setup.setup(%{proxy_rules: settings})

  assert Application.fetch_env!(:proxy_rules, :settings) == settings
end
```

- [ ] **Step 7: Run the Setup test and verify RED**

```bash
devenv shell -- mix test apps/gsmlg_config/test/gsmlg/config/setup_test.exs
```

Expected: `Application.fetch_env!/2` raises because Setup ignores `:proxy_rules`.

- [ ] **Step 8: Apply validated settings**

Add to `setup/1`:

```elixir
if config[:proxy_rules] != nil do
  setup_proxy_rules(config[:proxy_rules])
end
```

Add alongside `setup_scout/1`:

```elixir
def setup_proxy_rules(config) do
  Application.put_env(:proxy_rules, :settings, config || %{})
end
```

- [ ] **Step 9: Run both scoped config files and verify GREEN**

```bash
devenv shell -- mix test \
  apps/gsmlg_config/test/gsmlg/config/schema_test.exs \
  apps/gsmlg_config/test/gsmlg/config/setup_test.exs
```

Expected: all tests pass with 0 failures.

- [ ] **Step 10: Commit runtime configuration**

```bash
git add apps/gsmlg_config
git commit -m "feat(proxy-rules): register runtime configuration"
```

### Task 5: Include Proxy Rules in Both Umbrella Releases

**Files:**

- Modify: `mix.exs`
- Modify: `apps/gsmlg_admin_web/mix.exs`

- [ ] **Step 1: Run the release contract probe and verify RED**

```bash
devenv shell -- mix run --no-start -e '
releases = GSMLG.Umbrella.MixProject.project() |> Keyword.fetch!(:releases)

for release <- [:gsmlg_umbrella, :gsmlg_umbrella_standalone] do
  applications = releases |> Keyword.fetch!(release) |> Keyword.fetch!(:applications)
  unless Keyword.fetch!(applications, :proxy_rules) == :permanent do
    raise "#{release} does not start proxy_rules permanently"
  end
end
'
```

Expected: `KeyError` because `:proxy_rules` is absent.

- [ ] **Step 2: Add explicit release roots**

Add `proxy_rules: :permanent` after `gsmlg_scout_server: :permanent` in the
`gsmlg_umbrella` and `gsmlg_umbrella_standalone` application lists. Do not add
it to Commander or Scout Agent releases.

- [ ] **Step 3: Add the direct admin dependency**

Add this entry beside the other in-umbrella domain apps:

```elixir
{:proxy_rules, in_umbrella: true},
```

- [ ] **Step 4: Re-run the release probe and verify GREEN**

Run the Step 1 command again.

Expected: exit 0 with no output.

- [ ] **Step 5: Commit release wiring**

```bash
git add mix.exs apps/gsmlg_admin_web/mix.exs
git commit -m "build(proxy-rules): include app in umbrella releases"
```

### Task 6: Add Service Navigation

**Files:**

- Modify: `apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs`
- Modify: `apps/gsmlg_admin_web/test/gsmlg/admin_web/components/admin_navigation_test.exs`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/admin_menu.ex`

- [ ] **Step 1: Write failing menu-model tests**

Add:

```elixir
test "includes Proxy Rules under the service section" do
  service = Enum.find(AdminMenu.sections(), &(&1.id == "service"))

  assert %{id: "proxy_rules", title: "Proxy Rules"} =
           group = Enum.find(service.groups, &(&1.id == "proxy_rules"))

  assert [%{id: "proxy_rules_dashboard", label: "Dashboard", path: "/proxy-rules"}] =
           group.items
end

test "matches Proxy Rules routes to the service menu item" do
  assert AdminMenu.active_id(nil, "/proxy-rules") == "proxy_rules_dashboard"
  assert AdminMenu.group_open?(AdminMenu.find_group!("proxy_rules"), "proxy_rules_dashboard")
end
```

Add this rendered-navigation test:

```elixir
test "renders Proxy Rules as the active service branch" do
  html =
    render_component(&AdminNavigation.left_menu/1,
      active_menu: "proxy_rules_dashboard"
    )

  assert html =~ "Proxy Rules"
  assert html =~ ~s(href="/proxy-rules")
  assert html =~ ~r/<details(?=[^>]*data-menu-group="proxy_rules")(?=[^>]*open)/
  assert html =~ ~s(aria-current="page")
end
```

- [ ] **Step 2: Run navigation tests and verify RED**

```bash
devenv shell -- mix test \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/components/admin_navigation_test.exs
```

Expected: the Proxy Rules group and link are absent.

- [ ] **Step 3: Add the Service group**

Insert between Scout and Caddy:

```elixir
%{
  id: "proxy_rules",
  title: "Proxy Rules",
  items: [
    %{id: "proxy_rules_dashboard", label: "Dashboard", path: "/proxy-rules"}
  ]
},
```

- [ ] **Step 4: Re-run navigation tests and verify GREEN**

Run the Step 2 command again.

Expected: all tests pass with 0 failures.

- [ ] **Step 5: Commit navigation**

```bash
git add \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/admin_menu.ex \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/components/admin_navigation_test.exs
git commit -m "feat(admin): add proxy rules navigation"
```

### Task 7: Add the Authenticated Dashboard Empty State

**Files:**

- Modify: `apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs`
- Create: `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/router.ex`
- Create: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/proxy_rules_live/index.ex`

- [ ] **Step 1: Add the failing route contract test**

```elixir
test "exposes the Proxy Rules dashboard route" do
  paths = GSMLG.AdminWeb.Router |> Phoenix.Router.routes() |> Enum.map(& &1.path)
  assert "/proxy-rules" in paths
end
```

- [ ] **Step 2: Add failing LiveView tests**

Create `GSMLG.AdminWeb.ProxyRulesLiveTest` with this module setup, followed by
the behavior tests below:

```elixir
defmodule GSMLG.AdminWeb.ProxyRulesLiveTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import GSMLG.AccountsFixtures
  import Phoenix.LiveViewTest

  @secret_key_base String.duplicate("p", 64)

  setup %{conn: conn} do
    endpoint_config = Application.get_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, [])

    Application.put_env(
      :gsmlg_admin_web,
      GSMLG.AdminWeb.Endpoint,
      Keyword.put(endpoint_config, :secret_key_base, @secret_key_base)
    )

    on_exit(fn ->
      Application.put_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, endpoint_config)
    end)

    user = user_fixture()

    {:ok, token, _claims} =
      GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

    authenticated_conn =
      conn
      |> with_secret_key_base()
      |> Plug.Test.init_test_session(%{})
      |> Guardian.Plug.sign_in(
        GSMLG.AdminWeb.Guardian,
        user,
        %{},
        token_type: "access"
      )
      |> Plug.Conn.put_session(:guardian_default_token, token)

    %{
      conn: authenticated_conn,
      unauthenticated_conn: Phoenix.ConnTest.build_conn() |> with_secret_key_base()
    }
  end
```

```elixir
test "redirects unauthenticated requests to sign in", %{unauthenticated_conn: conn} do
  assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/proxy-rules")
end

test "renders the explicit not-ready dashboard state", %{conn: conn} do
  {:ok, view, html} = live(conn, ~p"/proxy-rules")

  assert html =~ "Proxy Rules"
  assert has_element?(view, "#proxy-rules-status", "Not ready")
  assert has_element?(view, "#proxy-rules-generation", "Not available")
  assert has_element?(view, "#proxy-rules-compiled-at", "Not available")
  assert has_element?(view, "#proxy-rules-proxy-count", "Not available")
  assert has_element?(view, "#proxy-rules-direct-count", "Not available")
  assert has_element?(view, "#proxy-rules-source-remote-gfwlist", "Not available")
  assert has_element?(view, "#proxy-rules-source-local-proxy-list", "Not available")
  assert has_element?(view, "#proxy-rules-source-local-direct-list", "Not available")
  assert has_element?(view, "#proxy-rules-artifacts-empty", "No artifacts have been published.")
  refute has_element?(view, "#proxy-rules-artifacts a")
end

test "marks navigation active and keeps refresh unavailable", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/proxy-rules")

  assert has_element?(view, "details[data-menu-group='proxy_rules'][open]")
  assert has_element?(view, "a[href='/proxy-rules'][aria-current='page']", "Dashboard")
  assert has_element?(view, "#proxy-rules-refresh[disabled][aria-disabled='true']")
  refute has_element?(view, "#proxy-rules-refresh[phx-click]")
end

defp with_secret_key_base(conn), do: %{conn | secret_key_base: @secret_key_base}
end
```

- [ ] **Step 3: Run dashboard tests and verify RED**

```bash
devenv shell -- mix test \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs
```

Expected: the route and LiveView are missing.

- [ ] **Step 4: Add the authenticated route**

Inside the existing scope using `[:browser, :maybe_browser_auth,
:ensure_authed_access]`, add after the Scout route:

```elixir
live("/proxy-rules", ProxyRulesLive.Index, :index)
```

- [ ] **Step 5: Implement the dashboard LiveView**

Create the complete LiveView module:

```elixir
defmodule GSMLG.AdminWeb.ProxyRulesLive.Index do
  use GSMLG.AdminWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:error, :not_ready} = GSMLG.ProxyRules.metadata()

    {:ok,
     assign(socket,
       page_title: "Proxy Rules",
       state: %{
         status: :not_ready,
         generation: nil,
         compiled_at: nil,
         proxy_count: nil,
         direct_count: nil,
         artifacts: [],
         sources: [
           %{id: "remote-gfwlist", label: "Remote GFWList"},
           %{id: "local-proxy-list", label: "Local proxy list"},
           %{id: "local-direct-list", label: "Local direct list"}
         ],
         diagnostics: [
           %{id: "invalid", label: "Invalid", value: nil},
           %{id: "unsupported", label: "Unsupported", value: nil},
           %{id: "duplicate", label: "Duplicate", value: nil},
           %{id: "collapsed", label: "Collapsed", value: nil},
           %{id: "conflict", label: "Conflict", value: nil}
         ]
       }
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} active_menu="proxy_rules_dashboard">
      <div id="proxy-rules-dashboard" class="space-y-8 p-6 lg:p-8">
        <header class="flex flex-col gap-4 md:flex-row md:justify-between">
          <div class="space-y-2">
            <div class="flex items-center gap-3">
              <h1 class="text-3xl font-bold">Proxy Rules</h1>
              <.dm_badge id="proxy-rules-status" variant="warning" soft>Not ready</.dm_badge>
            </div>
            <p class="text-on-surface-variant">
              No artifact has been published. Operational metadata will appear after the first
              successful compilation.
            </p>
          </div>

          <div class="space-y-2">
            <.dm_btn
              id="proxy-rules-refresh"
              variant="primary"
              disabled
              aria-disabled="true"
              aria-describedby="proxy-rules-refresh-help"
            >
              Refresh remote source
            </.dm_btn>
            <p id="proxy-rules-refresh-help" class="text-sm text-on-surface-variant">
              Remote source service is not available yet.
            </p>
          </div>
        </header>

        <section class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4" aria-label="Summary">
          <.dm_card id="proxy-rules-generation" variant="bordered">
            <:title>Generation</:title>
            <p>{display_value(@state.generation)}</p>
          </.dm_card>
          <.dm_card id="proxy-rules-compiled-at" variant="bordered">
            <:title>Compiled at</:title>
            <p>{display_value(@state.compiled_at)}</p>
          </.dm_card>
          <.dm_card id="proxy-rules-proxy-count" variant="bordered">
            <:title>Proxy rules</:title>
            <p>{display_value(@state.proxy_count)}</p>
          </.dm_card>
          <.dm_card id="proxy-rules-direct-count" variant="bordered">
            <:title>Direct rules</:title>
            <p>{display_value(@state.direct_count)}</p>
          </.dm_card>
        </section>

        <section class="space-y-4" aria-labelledby="proxy-rules-sources-heading">
          <h2 id="proxy-rules-sources-heading" class="text-2xl font-semibold">Sources</h2>
          <div class="grid gap-4 lg:grid-cols-3">
            <.dm_card
              :for={source <- @state.sources}
              id={"proxy-rules-source-#{source.id}"}
              variant="bordered"
            >
              <:title>{source.label}</:title>
              <.dm_badge variant="ghost" soft>Not available</.dm_badge>
            </.dm_card>
          </div>
        </section>

        <section aria-labelledby="proxy-rules-artifacts-heading">
          <.dm_card id="proxy-rules-artifacts" variant="bordered" body_class="space-y-4">
            <:title>
              <h2 id="proxy-rules-artifacts-heading" class="text-2xl font-semibold">
                Artifacts
              </h2>
            </:title>
            <.dm_table id="proxy-rules-artifacts-table" data={@state.artifacts} border hover>
              <:col :let={_artifact} label="List">—</:col>
              <:col :let={_artifact} label="Format">—</:col>
              <:col :let={_artifact} label="Size">—</:col>
              <:col :let={_artifact} label="ETag">—</:col>
              <:col :let={_artifact} label="Last modified">—</:col>
              <:col :let={_artifact} label="Download">—</:col>
            </.dm_table>
            <p id="proxy-rules-artifacts-empty" class="text-sm text-on-surface-variant">
              No artifacts have been published.
            </p>
          </.dm_card>
        </section>

        <section class="space-y-4" aria-labelledby="proxy-rules-diagnostics-heading">
          <h2 id="proxy-rules-diagnostics-heading" class="text-2xl font-semibold">
            Diagnostics
          </h2>
          <div id="proxy-rules-diagnostics" class="grid gap-4 sm:grid-cols-2 xl:grid-cols-5">
            <.dm_card
              :for={diagnostic <- @state.diagnostics}
              id={"proxy-rules-diagnostic-#{diagnostic.id}"}
              variant="bordered"
            >
              <:title>{diagnostic.label}</:title>
              <p>{display_value(diagnostic.value)}</p>
            </.dm_card>
          </div>
          <p id="proxy-rules-diagnostic-sample-empty" class="text-sm text-on-surface-variant">
            No diagnostic entries are available.
          </p>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp display_value(nil), do: "Not available"
  defp display_value(value), do: to_string(value)
end
```

Do not add `phx-click` or `handle_event/3`.

- [ ] **Step 6: Re-run dashboard tests and verify GREEN**

Run the Step 3 command again.

Expected: authenticated render, unauthenticated redirect, empty-state, active
navigation, and disabled-refresh tests all pass.

- [ ] **Step 7: Commit the dashboard shell**

```bash
git add \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/router.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/proxy_rules_live/index.ex \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs
git commit -m "feat(admin): add proxy rules dashboard shell"
```

### Task 8: Verify the Scoped Milestone

**Files:**

- Verify all files listed in this plan.

- [ ] **Step 1: Format only the touched Elixir files**

```bash
devenv shell -- mix format \
  apps/proxy_rules/mix.exs \
  apps/proxy_rules/lib/gsmlg/proxy_rules.ex \
  apps/proxy_rules/lib/gsmlg/proxy_rules/application.ex \
  apps/proxy_rules/lib/gsmlg/proxy_rules/supervisor.ex \
  apps/proxy_rules/lib/gsmlg/proxy_rules/store.ex \
  apps/proxy_rules/lib/gsmlg/proxy_rules/coordinator.ex \
  apps/proxy_rules/test/gsmlg/proxy_rules/application_test.exs \
  apps/proxy_rules/test/gsmlg/proxy_rules/store_test.exs \
  apps/proxy_rules/test/gsmlg/proxy_rules_test.exs \
  apps/gsmlg_config/lib/gsmlg/config/schema.ex \
  apps/gsmlg_config/lib/gsmlg/config/setup.ex \
  apps/gsmlg_config/test/gsmlg/config/schema_test.exs \
  apps/gsmlg_config/test/gsmlg/config/setup_test.exs \
  apps/gsmlg_admin_web/mix.exs \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/admin_menu.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/router.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/proxy_rules_live/index.ex \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/components/admin_navigation_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs \
  mix.exs
```

- [ ] **Step 2: Run the complete scoped test set**

```bash
devenv shell -- mix test \
  apps/proxy_rules/test \
  apps/gsmlg_config/test/gsmlg/config/schema_test.exs \
  apps/gsmlg_config/test/gsmlg/config/setup_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/components/admin_navigation_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs
```

Expected: 0 failures. If an out-of-scope test fails, report it and stop rather
than editing unrelated code.

- [ ] **Step 3: Compile with CI strictness**

```bash
devenv shell -- mix compile --warnings-as-errors
```

Expected: exit 0 with no warnings.

- [ ] **Step 4: Validate formatting and whitespace**

```bash
devenv shell -- mix format --check-formatted
git diff --check
```

Expected: both commands exit 0.

- [ ] **Step 5: Build the production release**

```bash
devenv shell -- env MIX_ENV=prod mix release gsmlg_umbrella --overwrite
```

Expected: the release assembles successfully with `:proxy_rules` included.

- [ ] **Step 6: Verify runtime inclusion**

```bash
_build/prod/rel/gsmlg_umbrella/bin/gsmlg_umbrella eval \
  'IO.inspect(Application.spec(:proxy_rules, :mod))'
```

Expected:

```text
{GSMLG.ProxyRules.Application, []}
```

- [ ] **Step 7: Inspect the final scope**

```bash
git status --short --branch
git diff origin/main...HEAD --stat
git log --oneline origin/main..HEAD
```

Expected: only the design, plan, Milestone 1 OTP/config/release files, and the
admin dashboard files appear.
