# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Development Commands

```bash
# Setup (all apps)
mix setup

# Run dev server (starts both web:4110 and admin:4111)
mix phx.server

# Run all tests
mix test

# Run tests for a specific app
mix test apps/gsmlg/test/
mix test apps/gsmlg_web/test/

# Run a single test file
mix test apps/gsmlg_web/test/gsmlg_web/controllers/blog_controller_test.exs

# Run a single test by line number
mix test apps/gsmlg_web/test/gsmlg_web/controllers/blog_controller_test.exs:42

# Compile with CI-level strictness
mix compile --warnings-as-errors

# Linting
mix format --check-formatted
mix credo --strict

# Database
mix ecto.create && mix ecto.migrate
mix ecto.gen.migration <name> -r GSMLG.Repo

# Build assets
mix assets.deploy

# Build Docker image (local, bypassing nexus mirror)
docker build -f Dockerfile.alpine \
  --build-arg HEX_MIRROR=https://repo.hex.pm \
  --build-arg NPM_CONFIG_REGISTRY=https://registry.npmjs.org \
  -t gsmlg-umbrella .

# Production release
MIX_ENV=prod mix release gsmlg_umbrella

# Release migrations
./bin/gsmlg_umbrella eval "GSMLG.Release.migrate()"
```

## CI

GitHub Actions runs on every push: `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, and `dialyzer` (non-blocking). Tests run on pushes to main/develop and PRs to main. CI uses Elixir 1.18 + OTP 28, PostgreSQL 16.

## Project Architecture

**Elixir umbrella** with 19 apps under `apps/`. The key ones:

| App | Purpose |
|-----|---------|
| `gsmlg` | Core domain: Ecto schemas, Repo, PubSub, supervision tree for all business services |
| `gsmlg_web` | Public Phoenix app (port 4110). LiveView + React via `phoenix_react_server` |
| `gsmlg_admin_web` | Admin Phoenix app (port 4111). Mnesia browser, AWS dashboards, Commander control |
| `gsmlg_config` | TOML-based config system. Loads config, validates via NimbleOptions, applies to Application env |
| `gsmlg_commander` | Dual-mode command system: agent (outbound WebSocket) or server (session management) |
| `gsmlg_component` | Shared React components rendered server-side via Bun |
| `gsmlg_telemetry` | Structured logging, metrics collection, file/console/CloudWatch backends |
| `gsmlg_mnesia` | Wrapper around Erlang Mnesia with query DSL, transactions, schema management |

Other utility apps: `gsmlg_aws`, `gsmlg_couchdb`, `gsmlg_pki`, `gsmlg_web_push`, `gsmlg_whois`, `gsmlg_mac`, `gsmlg_tor`, `gsmlg_socket`, `gsmlg_logger`, `gsmlg_nx`.

### Configuration System

Configuration flows through a custom TOML-based system, **not** standard Elixir config files alone:

1. **`config/runtime.exs`** calls `GSMLG.Config.Loader.load/1` which reads TOML files in priority order:
   - `GSMLG_CONFIG_PATH` env var (production: `/etc/gsmlg_umbrella.toml`)
   - `apps/gsmlg_config/priv/gsmlg.{env}.toml`
   - `apps/gsmlg_config/priv/gsmlg.toml` (fallback)
2. **`GSMLG.Config.Schema`** validates sections using NimbleOptions
3. **`GSMLG.Config.Setup`** applies validated config to Application env (Ecto Repo, Phoenix Endpoints, etc.)
4. **`GSMLG.Application.start/2`** also calls `GSMLG.Config.config() |> GSMLG.Config.Setup.setup()` synchronously before starting the supervision tree

When adding new config fields: update the TOML file, add to schema.ex, add to setup.ex, and update the default in `gsmlg.toml`.

### Supervision Tree

`GSMLG.Application` (core app) starts sequentially:
`SimpleCache → AWS → SessionProcess.Supervisor → TaskSupervisor → Repo → PubSub → CommandPlatform.Supervisor → Finch → WebPush.Subscriptions → Node.Supervisor → Chess.Supervisor`

`GSMLG.Web.Application`: `Telemetry → Endpoint`
`GSMLG.AdminWeb.Application`: `Telemetry → Endpoint → Guardian.DB.Sweeper`

### Database

PostgreSQL in production and CI. Dev supports both TCP (`POSTGRES_HOST`) and Unix socket (`PGHOST` env var set by devenv/nix). Ecto repo is `GSMLG.Repo` in the `gsmlg` app.

### Frontend

Hybrid rendering: Phoenix LiveView for most pages, React components via `phoenix_react_server` (Bun runtime). Shared components live in `apps/gsmlg_component/assets/component/`. Assets built with Tailwind CSS v4 and Bun.

### UI Framework: Duskmoon

This project uses two Duskmoon packages for all UI:

- **`@duskmoon-dev/core`** (npm) — Tailwind CSS plugin providing design tokens, utility classes, and component styles.
- **`phoenix_duskmoon`** (hex, `~> 9.0`) — Phoenix function components with the `.dm_` prefix (`dm_form`, `dm_input`, `dm_btn`, `dm_table`, `dm_modal`, etc.). Used in `gsmlg_web` and `gsmlg_admin_web`.

**Upstream repositories:**
- CSS: [duskmoon-dev/duskmoonui](https://github.com/duskmoon-dev/duskmoonui)
- Elements: [duskmoon-dev/duskmoon-elements](https://github.com/duskmoon-dev/duskmoon-elements)
- Components: [duskmoon-dev/phoenix-duskmoon-ui](https://github.com/duskmoon-dev/phoenix-duskmoon-ui)

**`phoenix_duskmoon` wraps `@duskmoon-dev/elements`** — the Elixir components render the custom elements from the elements package. Bugs or missing features may originate in any layer (CSS, elements, or Phoenix components).

**When any Duskmoon package has a bug or lacks a feature we need:** file an issue on the appropriate repo above (CSS issues → duskmoonui, element issues → duskmoon-elements, component issues → phoenix-duskmoon-ui) with the label `internal request`. Do NOT work around missing functionality locally without first filing the upstream issue.

## Critical Gotchas

### Mnesia + OTP Alarms
- Mnesia suspends ALL schema transactions when `disk_almost_full` or `system_memory_high_watermark` alarms fire
- **Never** call `create_table` or `set_storage_type` in GenServer `init/1` — use `handle_continue` + `Task.start`
- For ephemeral data (PTY sessions), use `ram_copies` not `disc_copies`
- The production server has limited RAM (~957MB), so `system_memory_high_watermark` triggers frequently

### Erlang Kernel Logger
- `config :kernel, :logger` in Elixir config files causes a build/boot crash: "Cannot configure base applications: [:kernel]"
- The default Erlang handler is removed in `rel/vm.args.eex` with `-kernel logger [{handler,default,undefined}]`
- Two early boot `=INFO REPORT====` messages (alarm_handler, mnesia) still appear via legacy error_logger path — this is expected

### Docker / Deployment
- Production server: `tkgsmlg`, Docker Compose at `/root/dc/docker-compose.yaml`
- Image: `ghcr.io/gsmlg-dev/gsmlg-umbrella:latest`
- The Nexus mirror (`nexus.gsmlg.net`) frequently times out — use official Hex/npm registries for local builds
- `GSMLG_CONFIG_PATH` must be set in docker-compose to point to the TOML config file

### Telemetry File Backend
- The file backend JSON-encodes all telemetry events. Phoenix events include `%Plug.Conn{}` in metadata, which has no `Jason.Encoder` implementation.
- `sanitize_for_json/1` in `file.ex` handles this by converting non-encodable terms (structs, PIDs, functions) to inspected strings before encoding.
- Use `GSMLG.Telemetry.info/2`, `error/2`, `span/3` instead of `Logger` directly for structured JSON logging in production.
