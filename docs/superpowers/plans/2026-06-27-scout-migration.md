# Scout Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate `/home/gao/Workspace/gsmlg-opt/scout` into this GSMLG umbrella as an admin-protected distributed Markdown fetch service.

**Architecture:** Keep Scout's runtime boundaries, but rename them into the GSMLG namespace and integrate only the dashboard/API into `gsmlg_admin_web`. The main `gsmlg_umbrella` release starts the Scout server runtime, while the Lightpanda agent remains an explicit separate release so browser workers do not start in the main web/admin deployment.

**Tech Stack:** Elixir 1.18 / OTP 28, Phoenix 1.8, LiveView, DuskMoon, RabbitMQ via `amqp`, NimblePool, GSMLG TOML config, Guardian admin auth.

---

## Design Decisions

1. Do not import `scout_web` as a third Phoenix endpoint. Move its useful routes into `GSMLG.AdminWeb`:
   - Live dashboard: `/scout`
   - JSON API: `/api/scout/fetch`, `/api/scout/fetch/sync`, `/api/scout/fetch/:job_id`
2. Do not keep Scout's file-backed `auth.txt` login. The dashboard uses existing admin browser auth. JSON routes use a new small bearer-token admin plug patterned after `GSMLG.AdminWeb.Plugs.GaoNoteMCPAuth`.
3. Do not keep `settings.yaml` or `yaml_elixir`. Add a `[scout]` TOML section in `apps/gsmlg_config/priv/gsmlg*.toml`, validate it in `GSMLG.Config.Schema`, and apply it through `GSMLG.Config.Setup`.
4. Do not add database tables in this migration. Scout currently tracks jobs and agent heartbeats in memory; keep that behavior.
5. Do not start the agent in the main release. Add a separate `gsmlg_scout_agent` release and gate the agent runtime with config/env.
6. Reuse existing `GSMLG.PubSub` for dashboard broadcasts. Do not start `Scout.PubSub`.
7. Improve the migrated agent command runner by replacing unsupervised `Task.async` with a `Task.Supervisor` owned by `gsmlg_scout_agent`.

## Source To Target Map

| Source | Target |
| --- | --- |
| `/home/gao/Workspace/gsmlg-opt/scout/apps/scout` | `apps/gsmlg_scout` |
| `/home/gao/Workspace/gsmlg-opt/scout/apps/scout_server` | `apps/gsmlg_scout_server` |
| `/home/gao/Workspace/gsmlg-opt/scout/apps/scout_agent` | `apps/gsmlg_scout_agent` |
| `/home/gao/Workspace/gsmlg-opt/scout/apps/scout_web/lib/scout_web/live/dashboard_live.ex` | `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/scout_live/dashboard_live.ex` |
| `/home/gao/Workspace/gsmlg-opt/scout/apps/scout_web/lib/scout_web/controllers/fetch_controller.ex` | `apps/gsmlg_admin_web/lib/gsmlg/admin_web/controllers/scout_fetch_controller.ex` |
| `/home/gao/Workspace/gsmlg-opt/scout/apps/scout_web/assets/css/app.css` | selected classes in `apps/gsmlg_admin_web/assets/css/main.css` |

Namespace substitutions:

| Old | New |
| --- | --- |
| `Scout.Fetch` | `GSMLG.Scout.Fetch` |
| `Scout.Settings` | `GSMLG.Scout.Settings` |
| `Scout.Security` | `GSMLG.Scout.Security` |
| `Scout.RabbitMQ` | `GSMLG.Scout.RabbitMQ` |
| `Scout.Server` | `GSMLG.Scout.Server` |
| `Scout.Agent` | `GSMLG.Scout.Agent` |
| `Scout.PubSub` | `GSMLG.PubSub` |
| `:scout` | `:gsmlg_scout` |
| `:scout_server` | `:gsmlg_scout_server` |
| `:scout_agent` | `:gsmlg_scout_agent` |
| `"scout:jobs"` | `"gsmlg_scout:jobs"` |
| `"scout:agents"` | `"gsmlg_scout:agents"` |

## File Structure

Create:

- `apps/gsmlg_scout/mix.exs`
- `apps/gsmlg_scout/lib/gsmlg/scout.ex`
- `apps/gsmlg_scout/lib/gsmlg/scout/settings.ex`
- `apps/gsmlg_scout/lib/gsmlg/scout/security.ex`
- `apps/gsmlg_scout/lib/gsmlg/scout/rabbitmq.ex`
- `apps/gsmlg_scout/lib/gsmlg/scout/markdown.ex`
- `apps/gsmlg_scout/lib/gsmlg/scout/fetch/job.ex`
- `apps/gsmlg_scout/lib/gsmlg/scout/fetch/result.ex`
- `apps/gsmlg_scout/lib/gsmlg/scout/fetch/retry_policy.ex`
- `apps/gsmlg_scout/test/gsmlg/scout/*_test.exs`
- `apps/gsmlg_scout_server/mix.exs`
- `apps/gsmlg_scout_server/lib/gsmlg/scout/server/application.ex`
- `apps/gsmlg_scout_server/lib/gsmlg/scout/server.ex`
- `apps/gsmlg_scout_server/lib/gsmlg/scout/server/job_manager.ex`
- `apps/gsmlg_scout_server/lib/gsmlg/scout/server/agent_registry.ex`
- `apps/gsmlg_scout_server/lib/gsmlg/scout/server/dispatcher.ex`
- `apps/gsmlg_scout_server/lib/gsmlg/scout/server/transport_disabled.ex`
- `apps/gsmlg_scout_server/lib/gsmlg/scout/server/result_handler.ex`
- `apps/gsmlg_scout_server/lib/gsmlg/scout/server/result_consumer.ex`
- `apps/gsmlg_scout_server/lib/gsmlg/scout/server/heartbeat_consumer.ex`
- `apps/gsmlg_scout_server/test/gsmlg/scout/server/job_manager_test.exs`
- `apps/gsmlg_scout_agent/mix.exs`
- `apps/gsmlg_scout_agent/lib/gsmlg/scout/agent/application.ex`
- `apps/gsmlg_scout_agent/lib/gsmlg/scout/agent.ex`
- `apps/gsmlg_scout_agent/lib/gsmlg/scout/agent/executor.ex`
- `apps/gsmlg_scout_agent/lib/gsmlg/scout/agent/lightpanda.ex`
- `apps/gsmlg_scout_agent/lib/gsmlg/scout/agent/lightpanda/cli.ex`
- `apps/gsmlg_scout_agent/lib/gsmlg/scout/agent/lightpanda_pool.ex`
- `apps/gsmlg_scout_agent/lib/gsmlg/scout/agent/amqp_consumer.ex`
- `apps/gsmlg_scout_agent/lib/gsmlg/scout/agent/heartbeat.ex`
- `apps/gsmlg_scout_agent/test/support/fake_lightpanda.ex`
- `apps/gsmlg_scout_agent/test/gsmlg/scout/agent/agent_test.exs`
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/controllers/scout_fetch_controller.ex`
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/scout_live/dashboard_live.ex`
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/plugs/admin_bearer_auth.ex`
- `apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/scout_fetch_controller_test.exs`
- `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/scout_live_test.exs`

Modify:

- `mix.exs`
- `mix.lock`
- `config/config.exs`
- `config/test.exs`
- `apps/gsmlg_config/lib/gsmlg/config/schema.ex`
- `apps/gsmlg_config/lib/gsmlg/config/setup.ex`
- `apps/gsmlg_config/priv/gsmlg.toml`
- `apps/gsmlg_config/priv/gsmlg.dev.toml`
- `apps/gsmlg_config/test/gsmlg/config/setup_test.exs`
- `apps/gsmlg/mix.exs` only if `gsmlg_scout_server` needs a hard dependency on the core app at runtime
- `apps/gsmlg_admin_web/mix.exs`
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/router.ex`
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/admin_menu.ex`
- `apps/gsmlg_admin_web/test/gsmlg/admin_web/components/admin_navigation_test.exs`
- `apps/gsmlg_admin_web/assets/css/main.css`

## Task 1: Import Core Scout Domain

**Files:**
- Create: `apps/gsmlg_scout/mix.exs`
- Create: `apps/gsmlg_scout/lib/gsmlg/scout/**/*.ex`
- Create: `apps/gsmlg_scout/test/gsmlg/scout/**/*_test.exs`

- [ ] **Step 1: Write failing core tests**

Create tests by copying the relevant source tests and applying the namespace changes:

- `/home/gao/Workspace/gsmlg-opt/scout/apps/scout/test/scout/settings_test.exs`
- `/home/gao/Workspace/gsmlg-opt/scout/apps/scout/test/scout/security_test.exs`
- `/home/gao/Workspace/gsmlg-opt/scout/apps/scout/test/scout/auth_tokens_test.exs` is not copied because file-backed auth is removed.

The first core test should assert TOML-shaped Application env is normalized into the old settings shape:

```elixir
defmodule GSMLG.Scout.SettingsTest do
  use ExUnit.Case, async: false

  alias GSMLG.Scout.Settings

  setup do
    previous = Application.get_env(:gsmlg_scout, :settings)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:gsmlg_scout, :settings)
        value -> Application.put_env(:gsmlg_scout, :settings, value)
      end
    end)

    :ok
  end

  test "normalizes application settings with defaults" do
    Application.put_env(:gsmlg_scout, :settings, %{
      general: %{instance_name: "Test Scout", default_region: "test"},
      fetch: %{default_timeout_ms: 1_000, max_timeout_ms: 2_000, retry: %{max_attempts: 2}},
      agent: %{id: "test-agent-1"}
    })

    settings = Settings.get()

    assert settings["general"]["instance_name"] == "Test Scout"
    assert settings["general"]["default_region"] == "test"
    assert settings["fetch"]["default_timeout_ms"] == 1_000
    assert settings["fetch"]["max_timeout_ms"] == 2_000
    assert settings["fetch"]["retry"]["max_attempts"] == 2
    assert settings["agent"]["id"] == "test-agent-1"
    assert settings["rabbitmq"]["queues"]["jobs"] == "scout.fetch.jobs"
  end
end
```

- [ ] **Step 2: Run tests and confirm missing modules**

Run:

```bash
devenv shell -- mix test apps/gsmlg_scout/test/gsmlg/scout/settings_test.exs apps/gsmlg_scout/test/gsmlg/scout/security_test.exs
```

Expected: fails because `GSMLG.Scout.Settings` and `GSMLG.Scout.Fetch.Job` do not exist yet.

- [ ] **Step 3: Create the core app mix file**

Create `apps/gsmlg_scout/mix.exs`:

```elixir
defmodule GSMLG.Scout.MixProject do
  use Mix.Project

  def project do
    [
      app: :gsmlg_scout,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:crypto, :logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:amqp, "~> 4.1"},
      {:jason, "~> 1.2"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end
end
```

- [ ] **Step 4: Copy and rename core modules**

Copy these source modules into `apps/gsmlg_scout/lib/gsmlg/scout/`, then apply the namespace substitution table from this plan:

- `apps/scout/lib/scout.ex`
- `apps/scout/lib/scout/security.ex`
- `apps/scout/lib/scout/rabbitmq.ex`
- `apps/scout/lib/scout/markdown.ex`
- `apps/scout/lib/scout/fetch/job.ex`
- `apps/scout/lib/scout/fetch/result.ex`
- `apps/scout/lib/scout/fetch/retry_policy.ex`

Do not copy `/home/gao/Workspace/gsmlg-opt/scout/apps/scout/lib/scout/application.ex`; the migrated core app has no runtime process.

- [ ] **Step 5: Implement pure settings access**

Create `apps/gsmlg_scout/lib/gsmlg/scout/settings.ex` as a pure module, not a GenServer. It should expose `get/0`, `default_settings/0`, and `normalize/1`. It should deep-stringify atom-key TOML config and deep-merge it into the copied source defaults.

Key behavior:

```elixir
def get do
  :gsmlg_scout
  |> Application.get_env(:settings, %{})
  |> normalize()
end
```

Keep the source default queues and security blocklist unchanged.

- [ ] **Step 6: Run core tests**

Run:

```bash
devenv shell -- mix test apps/gsmlg_scout/test
```

Expected: all `gsmlg_scout` tests pass.

- [ ] **Step 7: Commit**

```bash
git add apps/gsmlg_scout
git commit -m "feat: add gsmlg scout core"
```

## Task 2: Add GSMLG TOML Configuration For Scout

**Files:**
- Modify: `apps/gsmlg_config/lib/gsmlg/config/schema.ex`
- Modify: `apps/gsmlg_config/lib/gsmlg/config/setup.ex`
- Modify: `apps/gsmlg_config/priv/gsmlg.toml`
- Modify: `apps/gsmlg_config/priv/gsmlg.dev.toml`
- Modify: `apps/gsmlg_config/test/gsmlg/config/setup_test.exs`

- [ ] **Step 1: Add failing config setup test**

Add this test under `describe "setup/1"` or a new `describe "setup_scout/1"` in `apps/gsmlg_config/test/gsmlg/config/setup_test.exs`:

```elixir
test "configures scout settings" do
  config = %{
    general: %{instance_name: "GSMLG Scout", default_region: "local", request_timeout_ms: 30_000},
    rabbitmq: %{
      enabled: false,
      url: "amqp://guest:guest@localhost:5672",
      queues: %{
        jobs: "scout.fetch.jobs",
        results: "scout.fetch.results",
        failed: "scout.fetch.failed",
        heartbeat: "scout.agent.heartbeat"
      },
      regional_queues: %{eu: "scout.fetch.jobs.eu"}
    },
    fetch: %{
      default_timeout_ms: 30_000,
      max_timeout_ms: 60_000,
      max_page_size_bytes: 5_000_000,
      browser: %{wait_until: "network_idle", wait_for: nil, javascript: true},
      retry: %{max_attempts: 3, base_backoff_ms: 500, max_backoff_ms: 5_000, jitter: true}
    },
    agent: %{
      enabled: false,
      id: nil,
      region: "local",
      heartbeat_interval_ms: 10_000,
      capacity: 16,
      browser_instances: 2,
      page_concurrency: 16,
      lightpanda_path: "lightpanda"
    },
    security: %{
      allowed_schemes: ["http", "https"],
      redirect_limit: 5,
      blocked_cidrs: ["127.0.0.0/8"]
    }
  }

  Setup.setup_scout(config)

  assert Application.get_env(:gsmlg_scout, :settings) == config
end
```

Update setup cleanup to restore/delete `Application.get_env(:gsmlg_scout, :settings)`.

- [ ] **Step 2: Run the failing config test**

Run:

```bash
devenv shell -- mix test apps/gsmlg_config/test/gsmlg/config/setup_test.exs
```

Expected: fails because `setup_scout/1` is not defined.

- [ ] **Step 3: Add schema sections**

In `GSMLG.Config.Schema`, add `@scout_general_schema`, `@scout_rabbitmq_schema`, `@scout_fetch_schema`, `@scout_agent_schema`, and `@scout_security_schema`. Add `scout: %{...}` to `schema/0` and `get_section_schema(:scout)`.

Keep deeper nested maps as maps for this migration:

```elixir
@scout_rabbitmq_schema [
  enabled: [type: :boolean, default: false],
  url: [type: :string, default: "amqp://guest:guest@localhost:5672"],
  queues: [type: :map, default: %{}],
  regional_queues: [type: :map, default: %{}]
]
```

- [ ] **Step 4: Add setup function**

In `GSMLG.Config.Setup.setup/1`, call `setup_scout(config[:scout])` when present.

Add:

```elixir
def setup_scout(config) do
  Application.put_env(:gsmlg_scout, :settings, config || %{})
end
```

- [ ] **Step 5: Add default TOML config**

Add this section to both `apps/gsmlg_config/priv/gsmlg.toml` and `apps/gsmlg_config/priv/gsmlg.dev.toml`:

```toml
[scout.general]
instance_name = "GSMLG Scout"
default_region = "local"
request_timeout_ms = 30000

[scout.rabbitmq]
enabled = false
url = "amqp://guest:guest@localhost:5672"

[scout.rabbitmq.queues]
jobs = "scout.fetch.jobs"
results = "scout.fetch.results"
failed = "scout.fetch.failed"
heartbeat = "scout.agent.heartbeat"

[scout.rabbitmq.regional_queues]
eu = "scout.fetch.jobs.eu"
us = "scout.fetch.jobs.us"
asia = "scout.fetch.jobs.asia"

[scout.fetch]
default_timeout_ms = 30000
max_timeout_ms = 60000
max_page_size_bytes = 5000000

[scout.fetch.browser]
wait_until = "network_idle"
wait_for = ""
javascript = true

[scout.fetch.retry]
max_attempts = 3
base_backoff_ms = 500
max_backoff_ms = 5000
jitter = true

[scout.agent]
enabled = false
id = ""
region = "local"
heartbeat_interval_ms = 10000
capacity = 16
browser_instances = 2
page_concurrency = 16
lightpanda_path = "lightpanda"

[scout.security]
allowed_schemes = ["http", "https"]
redirect_limit = 5
blocked_cidrs = ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "::1/128", "fc00::/7"]
```

- [ ] **Step 6: Run config tests**

Run:

```bash
devenv shell -- mix test apps/gsmlg_config/test/gsmlg/config/setup_test.exs apps/gsmlg_config/test/gsmlg/config_test.exs
```

Expected: config tests pass.

- [ ] **Step 7: Commit**

```bash
git add apps/gsmlg_config config apps/gsmlg_config/priv
git commit -m "feat: configure scout through gsmlg toml"
```

## Task 3: Import Scout Server Runtime

**Files:**
- Create: `apps/gsmlg_scout_server/mix.exs`
- Create: `apps/gsmlg_scout_server/lib/gsmlg/scout/server/**/*.ex`
- Create: `apps/gsmlg_scout_server/lib/gsmlg/scout/server/transport_disabled.ex`
- Create: `apps/gsmlg_scout_server/test/gsmlg/scout/server/job_manager_test.exs`

- [ ] **Step 1: Write failing server tests**

Copy `/home/gao/Workspace/gsmlg-opt/scout/apps/scout_server/test/scout/server/job_manager_test.exs` to `apps/gsmlg_scout_server/test/gsmlg/scout/server/job_manager_test.exs` and apply namespace substitutions.

Also change PubSub subscription to:

```elixir
Phoenix.PubSub.subscribe(GSMLG.PubSub, "gsmlg_scout:jobs")
```

- [ ] **Step 2: Run and confirm missing server app**

Run:

```bash
devenv shell -- mix test apps/gsmlg_scout_server/test/gsmlg/scout/server/job_manager_test.exs
```

Expected: fails because `GSMLG.Scout.Server` modules do not exist.

- [ ] **Step 3: Create server app mix file**

Create `apps/gsmlg_scout_server/mix.exs`:

```elixir
defmodule GSMLG.ScoutServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :gsmlg_scout_server,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {GSMLG.Scout.Server.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:gsmlg, in_umbrella: true},
      {:gsmlg_scout, in_umbrella: true},
      {:phoenix_pubsub, "~> 2.1"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end
end
```

- [ ] **Step 4: Copy and rename server modules**

Copy these source modules into `apps/gsmlg_scout_server/lib/gsmlg/scout/server/` and apply namespace substitutions:

- `apps/scout_server/lib/scout/server.ex`
- `apps/scout_server/lib/scout/server/application.ex`
- `apps/scout_server/lib/scout/server/agent_registry.ex`
- `apps/scout_server/lib/scout/server/dispatcher.ex`
- `apps/scout_server/lib/scout/server/job_manager.ex`
- `apps/scout_server/lib/scout/server/result_handler.ex`
- `apps/scout_server/lib/scout/server/result_consumer.ex`
- `apps/scout_server/lib/scout/server/heartbeat_consumer.ex`

- [ ] **Step 5: Adjust server supervision**

In `GSMLG.Scout.Server.Application`, remove `{Phoenix.PubSub, name: Scout.PubSub}` from children. Keep only:

- `GSMLG.Scout.Server.AgentRegistry`
- `GSMLG.Scout.Server.JobManager`
- optional RabbitMQ result/failed/heartbeat consumers

Use `GSMLG.PubSub` in `AgentRegistry` and `JobManager` broadcasts.

- [ ] **Step 6: Make RabbitMQ-disabled dispatch explicit**

In `GSMLG.Scout.Server.Dispatcher.dispatch/1`, return a clear error when RabbitMQ is disabled and no test publisher is configured:

```elixir
def dispatch(%Job{} = job) do
  publisher().publish_job(job)
end

defp publisher do
  Application.get_env(:gsmlg_scout_server, :job_publisher) ||
    if GSMLG.Scout.RabbitMQ.enabled?() do
      GSMLG.Scout.RabbitMQ
    else
      GSMLG.Scout.Server.TransportDisabled
    end
end
```

Create `TransportDisabled.publish_job/1` to return:

```elixir
{:error, %{type: "transport_disabled", message: "Scout RabbitMQ transport is disabled", retryable: false}}
```

In `GSMLG.Scout.Server.JobManager`, keep explicit transport errors intact:

```elixir
defp dispatch_error(%{type: _type, message: _message, retryable: _retryable} = error), do: error
defp dispatch_error(reason), do: %{type: "dispatch_failed", message: inspect(reason), retryable: true}
```

- [ ] **Step 7: Run server tests**

Run:

```bash
devenv shell -- mix test apps/gsmlg_scout/test apps/gsmlg_scout_server/test
```

Expected: core and server tests pass.

- [ ] **Step 8: Commit**

```bash
git add apps/gsmlg_scout_server
git commit -m "feat: add gsmlg scout server runtime"
```

## Task 4: Import Scout Agent Runtime

**Files:**
- Create: `apps/gsmlg_scout_agent/mix.exs`
- Create: `apps/gsmlg_scout_agent/lib/gsmlg/scout/agent/**/*.ex`
- Create: `apps/gsmlg_scout_agent/test/support/fake_lightpanda.ex`
- Create: `apps/gsmlg_scout_agent/test/gsmlg/scout/agent/agent_test.exs`
- Modify: `config/test.exs`

- [ ] **Step 1: Write failing agent tests**

Copy:

- `/home/gao/Workspace/gsmlg-opt/scout/apps/scout_agent/test/scout/agent/agent_test.exs`
- `/home/gao/Workspace/gsmlg-opt/scout/apps/scout_agent/test/support/fake_lightpanda.ex`

Apply namespace substitutions and set:

```elixir
config :gsmlg_scout_agent, :lightpanda_adapter, GSMLG.Scout.Test.FakeLightpanda
```

in `config/test.exs`.

- [ ] **Step 2: Run and confirm missing agent app**

Run:

```bash
devenv shell -- mix test apps/gsmlg_scout_agent/test/gsmlg/scout/agent/agent_test.exs
```

Expected: fails because `GSMLG.Scout.Agent` modules do not exist.

- [ ] **Step 3: Create agent app mix file**

Create `apps/gsmlg_scout_agent/mix.exs`:

```elixir
defmodule GSMLG.ScoutAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :gsmlg_scout_agent,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {GSMLG.Scout.Agent.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:gsmlg_scout, in_umbrella: true},
      {:amqp, "~> 4.1"},
      {:jason, "~> 1.2"},
      {:nimble_pool, "~> 1.1"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end
end
```

- [ ] **Step 4: Copy and rename agent modules**

Copy these source modules into `apps/gsmlg_scout_agent/lib/gsmlg/scout/agent/` and apply namespace substitutions:

- `apps/scout_agent/lib/scout/agent.ex`
- `apps/scout_agent/lib/scout/agent/application.ex`
- `apps/scout_agent/lib/scout/agent/amqp_consumer.ex`
- `apps/scout_agent/lib/scout/agent/executor.ex`
- `apps/scout_agent/lib/scout/agent/heartbeat.ex`
- `apps/scout_agent/lib/scout/agent/lightpanda.ex`
- `apps/scout_agent/lib/scout/agent/lightpanda/cli.ex`
- `apps/scout_agent/lib/scout/agent/lightpanda_pool.ex`

- [ ] **Step 5: Gate agent startup from settings**

In `GSMLG.Scout.Agent.Application`, replace the source `SCOUT_AGENT_ENABLED` check with:

```elixir
defp agent_enabled? do
  settings = GSMLG.Scout.Settings.get()

  settings["agent"]["enabled"] == true ||
    System.get_env("GSMLG_SCOUT_AGENT_ENABLED") == "true" ||
    Mix.env() == :test
end
```

- [ ] **Step 6: Add supervised command execution**

Add `{Task.Supervisor, name: GSMLG.Scout.Agent.TaskSupervisor}` before `LightpandaPool` in the agent supervision tree.

In `GSMLG.Scout.Agent.Lightpanda.CLI`, replace `Task.async` with:

```elixir
task =
  Task.Supervisor.async_nolink(GSMLG.Scout.Agent.TaskSupervisor, fn ->
    System.cmd(path, args, stderr_to_stdout: true)
  end)
```

- [ ] **Step 7: Use configured pool size and capacity**

In `GSMLG.Scout.Agent.LightpandaPool.start_link/1`, use `settings["agent"]["browser_instances"]` as the default `pool_size`.

In `GSMLG.Scout.Agent.status/0`, return `settings["agent"]["capacity"]` instead of hardcoded `1`.

- [ ] **Step 8: Run agent tests**

Run:

```bash
devenv shell -- mix test apps/gsmlg_scout_agent/test apps/gsmlg_scout/test
```

Expected: agent and core tests pass.

- [ ] **Step 9: Commit**

```bash
git add apps/gsmlg_scout_agent config/test.exs
git commit -m "feat: add gsmlg scout agent runtime"
```

## Task 5: Wire Releases And Dependencies

**Files:**
- Modify: `mix.exs`
- Modify: `apps/gsmlg_admin_web/mix.exs`
- Modify: `mix.lock`

- [ ] **Step 1: Add app dependencies**

In `apps/gsmlg_admin_web/mix.exs`, add:

```elixir
{:gsmlg_scout_server, in_umbrella: true}
```

The admin web layer should not depend on `gsmlg_scout_agent`.

- [ ] **Step 2: Add releases**

In root `mix.exs`, add `gsmlg_scout_server: :permanent` to both `gsmlg_umbrella` and `gsmlg_umbrella_standalone` release applications, after `gsmlg: :permanent`.

Add a separate release:

```elixir
gsmlg_scout_agent: [
  include_executables_for: [:unix],
  steps: [:assemble, :tar],
  applications: [
    gsmlg_scout: :permanent,
    gsmlg_scout_agent: :permanent
  ]
]
```

- [ ] **Step 3: Fetch dependency lock changes**

Run:

```bash
devenv shell -- mix deps.get
```

Expected: `mix.lock` gains `amqp`, `amqp_client`, `rabbit_common`, and related RabbitMQ deps if they are not already present.

- [ ] **Step 4: Compile Scout apps**

Run:

```bash
devenv shell -- mix compile --warnings-as-errors
```

Expected: compile passes.

- [ ] **Step 5: Commit**

```bash
git add mix.exs mix.lock apps/gsmlg_admin_web/mix.exs
git commit -m "feat: wire scout releases"
```

## Task 6: Migrate Dashboard And JSON API Into Admin Web

**Files:**
- Create: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/controllers/scout_fetch_controller.ex`
- Create: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/scout_live/dashboard_live.ex`
- Create: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/plugs/admin_bearer_auth.ex`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/router.ex`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/admin_menu.ex`
- Modify: `apps/gsmlg_admin_web/assets/css/main.css`
- Create: `apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/scout_fetch_controller_test.exs`
- Create: `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/scout_live_test.exs`

- [ ] **Step 1: Write failing admin API tests**

Create `apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/scout_fetch_controller_test.exs`. Use the same authenticated connection setup style as `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs`.

Required test cases:

- unauthenticated `POST /api/scout/fetch` returns `401`
- authenticated `POST /api/scout/fetch` queues a job with a fake publisher
- authenticated `POST /api/scout/fetch/sync` returns markdown with a fake publisher
- authenticated private-network URL returns `422` with `"blocked_target"`

- [ ] **Step 2: Write failing dashboard tests**

Create `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/scout_live_test.exs`.

Required test cases:

- unauthenticated users are redirected to `/sign_in`
- authenticated users can render `/scout`
- completed fetch results show the DuskMoon markdown modal
- `GSMLG.AdminWeb.AdminMenu` renders a "Scout" item under the Service section

- [ ] **Step 3: Run failing admin tests**

Run:

```bash
devenv shell -- env DATABASE_URL=postgres://gsmlg_dev:gsmlg_dev@localhost/gsmlg_test mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/scout_fetch_controller_test.exs apps/gsmlg_admin_web/test/gsmlg/admin_web/live/scout_live_test.exs
```

Expected: fails because routes/controllers/live views do not exist.

- [ ] **Step 4: Add admin bearer auth plug**

Create `GSMLG.AdminWeb.Plugs.AdminBearerAuth` by reusing only the bearer-token branch from `GSMLG.AdminWeb.Plugs.GaoNoteMCPAuth`. It should accept `Authorization: Bearer <admin access token>`, call `GSMLG.AdminWeb.Guardian.resource_from_token(token, %{"typ" => "access"}, [])`, put the Guardian current resource, assign `:actor`, and call `GSMLG.AdminWeb.Guardian.ApiAuthErrorHandler.auth_error/2` on failure.

- [ ] **Step 5: Add routes**

In the authenticated browser scope, add:

```elixir
live("/scout", ScoutLive.DashboardLive, :index)
```

Add a new API scope:

```elixir
scope "/api/scout", GSMLG.AdminWeb do
  pipe_through([:api, :admin_bearer_auth])

  post("/fetch", ScoutFetchController, :create)
  post("/fetch/sync", ScoutFetchController, :sync)
  get("/fetch/:job_id", ScoutFetchController, :show)
end
```

Add the `:admin_bearer_auth` pipeline:

```elixir
pipeline :admin_bearer_auth do
  plug(GSMLG.AdminWeb.Plugs.AdminBearerAuth)
end
```

- [ ] **Step 6: Port fetch controller**

Port source `ScoutWeb.FetchController` into `GSMLG.AdminWeb.ScoutFetchController`, replacing `Scout.Server` with `GSMLG.Scout.Server` and `Scout.Fetch.Result` with `GSMLG.Scout.Fetch.Result`.

Keep response status behavior:

- async create success: `202`
- sync success: `200`
- sync failed fetch result: `422`
- invalid URL/private target: `422`
- missing job: `404`

- [ ] **Step 7: Port dashboard live view**

Port source `ScoutWeb.DashboardLive` into `GSMLG.AdminWeb.ScoutLive.DashboardLive`.

Required changes:

- `use GSMLG.AdminWeb, :live_view`
- Wrap render with `<Layouts.app flash={@flash} page_title={@page_title} active_menu="scout_dashboard">`
- Subscribe to `GSMLG.PubSub` topics `"gsmlg_scout:jobs"` and `"gsmlg_scout:agents"`
- Replace `Scout.Server` with `GSMLG.Scout.Server`
- Keep DuskMoon controls and markdown modal
- Remove logout link because the admin shell already owns sign-out

- [ ] **Step 8: Add admin navigation**

In `GSMLG.AdminWeb.AdminMenu`, under the Service section, add a `Scout` group:

```elixir
%{
  id: "scout",
  title: "Scout",
  items: [
    %{id: "scout_dashboard", label: "Dashboard", path: "/scout"}
  ]
}
```

Update `apps/gsmlg_admin_web/test/gsmlg/admin_web/components/admin_navigation_test.exs` to assert the `Scout` group renders and opens when `active_menu: "scout_dashboard"`.

- [ ] **Step 9: Port only required CSS**

Move the dashboard layout/status classes from source `apps/scout_web/assets/css/app.css` into `apps/gsmlg_admin_web/assets/css/main.css`, renamed with a `scout-` prefix to avoid collisions:

- `.dashboard-page` -> `.scout-dashboard-page`
- `.dashboard-header` -> `.scout-dashboard-header`
- `.header-metrics` -> `.scout-header-metrics`
- `.fetch-band` -> `.scout-fetch-band`
- `.fetch-form` -> `.scout-fetch-form`
- `.dashboard-grid` -> `.scout-dashboard-grid`
- `.work-surface` -> `.scout-work-surface`
- `.status-pill` -> `.scout-status-pill`
- `.status-ok` -> `.scout-status-ok`
- `.status-running` -> `.scout-status-running`
- `.status-queued` -> `.scout-status-queued`
- `.status-error` -> `.scout-status-error`

Do not import Scout's Tailwind or DuskMoon package versions; the admin app already has newer DuskMoon packages.

- [ ] **Step 10: Run admin tests**

Run:

```bash
devenv shell -- env DATABASE_URL=postgres://gsmlg_dev:gsmlg_dev@localhost/gsmlg_test mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/scout_fetch_controller_test.exs apps/gsmlg_admin_web/test/gsmlg/admin_web/live/scout_live_test.exs apps/gsmlg_admin_web/test/gsmlg/admin_web/components/admin_navigation_test.exs
```

Expected: targeted admin tests pass.

- [ ] **Step 11: Commit**

```bash
git add apps/gsmlg_admin_web
git commit -m "feat: add scout admin dashboard"
```

## Task 7: Full Verification

**Files:**
- No new files unless verification reveals a defect.

- [ ] **Step 1: Format**

Run:

```bash
devenv shell -- mix format
```

Expected: files are formatted.

- [ ] **Step 2: Focused test suite**

Run:

```bash
devenv shell -- mix test apps/gsmlg_scout/test apps/gsmlg_scout_server/test apps/gsmlg_scout_agent/test
```

Expected: all Scout tests pass without PostgreSQL.

- [ ] **Step 3: Admin integration tests**

Run:

```bash
devenv shell -- env DATABASE_URL=postgres://gsmlg_dev:gsmlg_dev@localhost/gsmlg_test mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/scout_fetch_controller_test.exs apps/gsmlg_admin_web/test/gsmlg/admin_web/live/scout_live_test.exs apps/gsmlg_admin_web/test/gsmlg/admin_web/components/admin_navigation_test.exs
```

Expected: admin Scout tests pass. If the test database is behind, run pending migrations for `gsmlg_test` before rerunning this slice.

- [ ] **Step 4: Compile with CI strictness**

Run:

```bash
devenv shell -- mix compile --warnings-as-errors
```

Expected: compile succeeds without warnings.

- [ ] **Step 5: Optional browser check**

Start the app:

```bash
devenv shell -- mix phx.server
```

Open `http://localhost:4111/scout`, sign in with an admin account, and confirm:

- "Scout" appears in the admin navigation
- `/scout` renders the dashboard
- submitting `https://example.com/docs` shows a clear transport-disabled error when RabbitMQ is disabled
- when a fake or real RabbitMQ publisher is configured, a completed job shows markdown in the modal

- [ ] **Step 6: Final status**

Run:

```bash
git status --short
```

Expected: only intended Scout migration files are modified.

## Rollback Plan

If implementation exposes a release-start problem, remove `gsmlg_scout_server: :permanent` from the main releases first. That preserves the imported apps and admin code for follow-up while keeping `gsmlg_umbrella` bootable. If the admin UI is the problem, remove only the `/scout` route and admin menu item; core/server/agent apps can remain compiled but unused.

## Self-Review

- Scope coverage: core fetch structs, URL security, RabbitMQ transport, server job lifecycle, agent Lightpanda execution, admin dashboard, JSON API, GSMLG TOML config, and release wiring are all covered.
- Auth coverage: source file-token auth is intentionally removed; dashboard uses admin session auth and API uses bearer admin auth.
- Runtime safety: main release starts server runtime only; agent runtime is opt-in and separate.
- Database impact: no migrations or schemas are planned.
- DuskMoon compliance: dashboard uses existing DuskMoon components and admin asset pipeline; no DaisyUI dependency is introduced.
