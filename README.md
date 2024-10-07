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

Server need mariadb as a service.

Create db scripts

# Build

I'm using nix develop shell to build package.

## Build standalone binary

```shell
MIX_ENV=prod BURRITO_TARGET=linux_amd64 mix release gsmlg_umbrella_standalone
```
