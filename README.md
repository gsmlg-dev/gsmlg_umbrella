# GSMLG Umbrella

Personal service platform built with Elixir/Phoenix. Runs two web apps (public + admin), a command platform, and various utility services under a single OTP umbrella.

Docker image: [ghcr.io/gsmlg-dev/gsmlg-umbrella](https://github.com/gsmlg-dev/gsmlg_umbrella/pkgs/container/gsmlg-umbrella)

## Applications

| App | Port | Purpose |
|-----|------|---------|
| `gsmlg_web` | 4110 | Public-facing Phoenix app (LiveView + React) |
| `gsmlg_admin_web` | 4111 | Admin dashboard (Mnesia browser, AWS, Commander) |
| `gsmlg_commander` | — | Dual-mode command system (WebSocket agent or session server) |

## Quick Start

Requires Elixir >= 1.18.0 and Erlang/OTP >= 28.0. The
[devenv](https://devenv.sh/) environment provides Elixir 1.18.5 on OTP 28;
CI and Docker builders use Elixir 1.18.4 on OTP 28.

```shell
devenv shell        # starts PostgreSQL, sets DATABASE_URL
mix setup           # install deps, create DB, run migrations
mix phx.server      # http://localhost:4110 and http://localhost:4111
```

Both Phoenix endpoints use `Gaoxy.PhoenixAdapter` from `gaoxy_http`. Explicit
`websock_adapter` overrides select the matching `gaoxy_websock_adapter` Hex
distribution for LiveView and Channels. TOML still controls each endpoint's
port and `server` flag. HTTP test fixtures also use Gaoxy. HTTP clients use
http_fetch through Tesla or direct streaming transports, and CDP uses
http_web_socket.

Finch and Mint remain indirect dependencies: `backplane_mcp_protocol` requires
Finch ([upstream tracking](https://github.com/gsmlg-opt/backplane/issues/120)),
and the Burrito build tool requires Req, which also requires Finch. Complete
removal awaits supported upstream releases for these paths. Bandit and
mint_web_socket are no longer required.

Direct Hex dependencies use `~> major.minor` requirements. Resolved versions
are recorded in `mix.lock`.

The SVG-to-React toolbox entry and page remain available, with conversion
temporarily disabled and Babel/SVGR dependencies removed.

Toolbox pages use `duskmoon_hologram` 10.0 with the existing `Hologram.*` API,
`:hologram` compiler and `/hologram/` routes. Configure the fork under
`:duskmoon_hologram`; the upstream `hologram` package must not be installed
alongside it. `mix phx.server` and `mix test` enable it with `HOLOGRAM_START=1`
from either the umbrella root or `apps/gsmlg_web`.

Both web apps use `duskmoon_bundler` 10.0.8 for JavaScript, Tailwind CSS v4 and
development HMR. Run `mix npm.install` at the umbrella root to install the
workspace dependencies; commit `package-lock.json` and use `mix npm.ci` for
frozen installs. When migrating an existing Bun checkout, remove the generated
`node_modules` directories in the three JS workspaces before installing; stale
Bun workspace copies can shadow the new root workspace links.
`mix assets.build` builds both apps, and `mix assets.deploy`
builds production assets with manifests and Phoenix digests. Each app also
provides these aliases when run from its directory. The development endpoints
serve JavaScript modules at `/assets/js/` and watcher-built CSS at `/assets/css/`.
Service workers are static files at `/sw.js`.

Vize uses its supported source build mode because the published GNU binaries
require glibc 2.43. The existing Rust/Cargo toolchain builds it for the host
environment, including Nix and the Debian Docker builder.

Version 10.0.8 includes fixes for minified SharedWorker URLs
([#11](https://github.com/duskmoon-dev/duskmoon-bundler/issues/11)), scope-aware
`process.env.NODE_ENV` replacement in development
([#12](https://github.com/duskmoon-dev/duskmoon-bundler/issues/12)), and worker-safe
development bootstrap
([#13](https://github.com/duskmoon-dev/duskmoon-bundler/issues/13)).

Source environment checks use `import.meta.env.DEV` / `import.meta.env.MODE`.

Bun is still required by `phoenix_react_server` for React server-side rendering
and its release bundle, and by the existing JavaScript tests. Frontend asset
builds and npm dependency installs use Mix. Set `MIX_BUN_PATH`, `BUN_BIN`, or
the TOML `gsmlg.bun_path` to configure the SSR executable, in that order.
The legacy TOML `tailwind_path` is accepted but ignored; no Tailwind CLI is
required.

Concord and ExTurso use the 3.1 release line. Concord 3.1.6 supports the
process-local controller PIDs required by PTY session attachment through
`Concord.Local`; these session records remain local to the current BEAM node.

ExTurso builds its native library from source and requires Rust/Cargo 1.91 or
newer, a C compiler, Make, Perl, and CMake. The devenv shell and Docker builders
provide these tools.

## Database

```shell
mix ecto.create && mix ecto.migrate
mix ecto.gen.migration <name> -r GSMLG.Repo
```

## Deployment

### Docker

```shell
docker pull ghcr.io/gsmlg-dev/gsmlg-umbrella:latest

docker exec <container> /app/bin/gsmlg_umbrella eval "GSMLG.Release.migrate()"
docker exec <container> /app/bin/gsmlg_umbrella eval "GSMLG.Release.list_users()"
docker exec <container> /app/bin/gsmlg_umbrella eval 'GSMLG.Release.reset_password("admin@example.com", "newpassword")'
```

Requires `GSMLG_CONFIG_PATH` env var pointing to a TOML config file (see `apps/gsmlg_config/priv/gsmlg.toml` for defaults).

### Elixir Release

```shell
MIX_ENV=prod mix release gsmlg_umbrella
./bin/gsmlg_umbrella eval "GSMLG.Release.migrate()"
```

### Standalone Binary (Burrito)

```shell
MIX_ENV=prod BURRITO_TARGET=linux_amd64 mix release gsmlg_umbrella_standalone
```

## Supported Languages

### Blog Content

Blog content supports multilingual translations via AI (Claude) or manual editing.

| Locale | Language |
|--------|----------|
| `en` | English |
| `zh-Hans` | Chinese (Simplified) |
| `zh-Hant` | Chinese (Traditional) |
| `fr` | French |
| `es` | Spanish |
| `de` | German |
| `it` | Italian |
| `ja` | Japanese |

Default locale is `zh-Hans` (configurable via `i18n.default_locale` in the TOML config).

### UI Translations (Gettext)

UI strings in `apps/gsmlg_component` and `apps/gsmlg_web` are translated via [Gettext](https://hexdocs.pm/gettext/).

**`apps/gsmlg_component`** — backend: `GSMLG.Component.Gettext`

| Domain | Description |
|--------|-------------|
| `github` | GitHub-related UI strings |

**`apps/gsmlg_web`** — backend: `GSMLG.Web.Gettext`

| Domain | Description |
|--------|-------------|
| `default` | General UI strings |
| `errors` | Error messages |
| `github` | GitHub-related UI strings |
| `homepage` | Homepage content |
| `menu` | Navigation menu |
| `toolbox` | Toolbox feature |
| `user` | User account UI |

Supported locales:

| Locale | Language |
|--------|----------|
| `en` | English |
| `zh-Hans` | Chinese (Simplified) |
| `zh-Hant` | Chinese (Traditional) |
| `fr` | French |
| `es` | Spanish |
| `de` | German |
| `it` | Italian |
| `ja` | Japanese |

> **Note:** `zh-Hans` / `zh-Hant` use BCP 47 script subtags. `GSMLG.Component.Gettext.Plural`
> maps them to the `zh` plural rules (1 form) so both `gettext` and `ngettext` work correctly.

To add a new locale or sync strings after source changes:

```shell
# Extract new strings into .pot template files
mix gettext.extract --merge --app gsmlg_web
mix gettext.extract --merge --app gsmlg_component

# Add a new locale (e.g. ko)
mix gettext.merge apps/gsmlg_web/priv/gettext --locale ko
mix gettext.merge apps/gsmlg_component/priv/gettext --locale ko
```

Then edit the generated `.po` files under `priv/gettext/<locale>/LC_MESSAGES/`.

## Releases

The root project and every application under `apps/` share one version. Child
projects keep their own version literals so published Hex packages work without
this repository. CI rejects version drift, including newly added applications.
Root and application `package.json` files with their own version share it too;
dependency version requirements are preserved.

```shell
scripts/update_version.sh 1.2.3   # update root and every apps/*/mix.exs
scripts/update_version.sh --check
```

The manual GitHub `release` workflow stamps the requested version into a source
commit and tag, builds all targets from that commit, and publishes opted-in Hex
packages at the same version before creating the GitHub release. Configure
`HEX_API_KEY` with publishing access to all enabled packages, including permission
to create new packages. Publication failure fails the release; matching package
archives can be safely retried. See [the release guide](docs/deploy.md#github-release-workflow)
for package selection, archives and retry behavior.
