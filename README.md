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

## Releases

Releases are automated via GitHub Actions (`release` workflow). Trigger manually with a version number — it builds the Docker image and Elixir tarballs in parallel, then publishes a GitHub release.

```shell
scripts/update_version.sh 1.2.3   # bump version in all mix.exs files
```
