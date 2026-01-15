# GSMLG.Umbrella

My app service, that create by elixir.

Automate build and release.

Publish compiled code to github release.

## Applications

- gsmlg

- gsmlg_web

- gsmlg_admin_web

- gsmlg_commander

## Database

Server requires PostgreSQL as a database service.

### Development Setup

```shell
# Create the database
mix ecto.create

# Run migrations
mix ecto.migrate

# Rollback (if needed)
mix ecto.rollback
```

### Production / Release Migrations

When running the compiled release, use the built-in release commands:

```shell
# Run all pending migrations
./bin/gsmlg_umbrella eval "GSMLG.Release.migrate()"

# Rollback to a specific version
./bin/gsmlg_umbrella eval "GSMLG.Release.rollback(GSMLG.Repo, 20231001000000)"
```

For Docker deployments:

```shell
docker exec <container> /app/bin/gsmlg_umbrella eval "GSMLG.Release.migrate()"
```

# Build

I'm using nix develop shell to build package.

## Build standalone binary

```shell
MIX_ENV=prod BURRITO_TARGET=linux_amd64 mix release gsmlg_umbrella_standalone
```

# Docker Image

[Repo in github](https://github.com/gsmlg-dev/gsmlg_umbrella/pkgs/container/gsmlg-umbrella)
