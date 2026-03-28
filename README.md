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

Requires [devenv](https://devenv.sh/) (Nix-based):

```shell
devenv shell        # starts PostgreSQL, sets DATABASE_URL
mix setup           # install deps, create DB, run migrations
mix phx.server      # http://localhost:4110 and http://localhost:4111
```

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

Releases are automated via GitHub Actions (`release` workflow). Trigger manually with a version number — it builds the Docker image and Elixir tarballs in parallel, then publishes a GitHub release.

```shell
scripts/update_version.sh 1.2.3   # bump version in all mix.exs files
```
