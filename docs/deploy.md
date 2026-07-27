# Deployment Guide

This guide covers deployment for the three release targets in this umbrella:

| Release | Purpose | Artifact |
| --- | --- | --- |
| `gsmlg_umbrella` | Main service: public web, admin web, database-backed domain services, Scout server, Commander platform | `gsmlg.tar.gz` or Docker image |
| `gsmlg_commander` | Remote Commander worker that connects back to the admin platform over WebSocket | `commander-<os>-<arch>.tar.gz` |
| `gsmlg_scout_agent` | Remote Scout fetch worker that consumes RabbitMQ jobs and runs Lightpanda | `gsmlg_scout_agent.tar.gz` |

The GitHub `release` workflow builds all three tarballs and the umbrella Docker image. Nix flakes also expose all three packages.

## Prerequisites

Production hosts need:

- PostgreSQL reachable by the umbrella app.
- RabbitMQ reachable by the umbrella app and Scout agents when Scout distributed fetching is enabled.
- `openssl` and system CA certificates for release hosts.
- `bun` on the umbrella host when running the tarball release directly. The Docker image already includes Bun and sets the component server path.
- Lightpanda for Scout agents, either as a native executable or through a local wrapper script that runs Docker.

Generate production secrets before deploying. Do not reuse checked-in development secrets.

```bash
mix phx.gen.secret
```

## Build And Release Artifacts

### GitHub Release Workflow

Dispatch `.github/workflows/release.yml` with a semantic version and a revision:

```bash
gh workflow run release.yml \
  -f release-version=5.6.0 \
  -f revision=$(git rev-parse HEAD)
```

The workflow publishes:

- `gsmlg.tar.gz`
- `commander-linux-amd64.tar.gz`
- `commander-linux-arm64.tar.gz`
- `commander-macos-amd64.tar.gz`
- `commander-macos-arm64.tar.gz`
- `commander-windows-amd64.tar.gz`
- `commander-freebsd-amd64.tar.gz`
- `gsmlg_scout_agent.tar.gz`
- `ghcr.io/gsmlg-dev/gsmlg-umbrella:v<version>`
- `ghcr.io/gsmlg-dev/gsmlg-umbrella:latest`

Download release tarballs from:

```text
https://github.com/gsmlg-dev/gsmlg_umbrella/releases/download/v<VERSION>/<ARTIFACT>
```

### Local Mix Releases

```bash
MIX_ENV=prod mix deps.get
MIX_ENV=prod mix compile
MIX_ENV=prod mix prerelease
MIX_ENV=prod mix release gsmlg_umbrella --overwrite
MIX_ENV=prod mix release gsmlg_commander --overwrite
MIX_ENV=prod mix release gsmlg_scout_agent --overwrite
```

Local release outputs are created under `_build/prod/rel/<release_name>`.

### Nix Packages

```bash
nix build .#gsmlg-umbrella
nix build .#gsmlg-commander
nix build .#gsmlg_scout_agent
```

The default flake package is `gsmlg-umbrella`.

## Shared Runtime Configuration

All releases load TOML configuration through `GSMLG_CONFIG_PATH`.

```bash
export GSMLG_CONFIG_PATH=/etc/gsmlg_umbrella.toml
```

If `GSMLG_CONFIG_PATH` is unset, the `gsmlg_commander` release uses
`$HOME/.config/gsmlg/commander/config.toml` by default and creates that file when
it does not exist. Other releases fall back to the embedded files from
`apps/gsmlg_config/priv/`.

Use separate config files per host when the roles differ:

- `/etc/gsmlg_umbrella.toml` for the main service.
- `$HOME/.config/gsmlg/commander/config.toml` for Commander workers.
- `/etc/gsmlg_scout_agent.toml` for Scout agents.

### Main Service Config

Minimal shape for the umbrella service:

```toml
[database]
username = "gsmlg"
password = "CHANGE_ME"
hostname = "postgres.example.internal"
port = 5432
database = "gsmlg_prod"
pool_size = 10
show_sensitive_data_on_connection_error = false

[web]
url = "https://gsmlg.example.com"
secret_key_base = "CHANGE_ME"
port = 4110
server = true
user_register = false
enable_adsense = false
show_icp = false

[admin_web]
url = "https://admin.gsmlg.example.com"
secret_key_base = "CHANGE_ME"
port = 4111
server = true
user_register = false

[commander]
start = false
name = "platform"
platform_url = "wss://admin.gsmlg.example.com/commander-socket/websocket"
platform_key = "CHANGE_ME_SHARED_COMMANDER_KEY"

[scout.rabbitmq]
enabled = true
url = "amqp://scout:CHANGE_ME@rabbitmq.example.internal:5672"
```

The umbrella app starts the public endpoint, admin endpoint, Scout server, and supporting domain services. It also provides the admin-side Commander and Scout dashboards.

### Commander Worker Config

Commander workers connect outbound to the admin platform:

```toml
[commander]
start = true
server = false
name = "commander-edge-01"
umbrella_server_url = "https://admin.gsmlg.example.com"
platform_key = "CHANGE_ME_SHARED_COMMANDER_KEY"
features = ["pty"]
```

`platform_key` must match the key configured for the admin platform. The worker does not need inbound ports opened.

### Scout Agent Config

Scout agents consume RabbitMQ jobs and publish results/heartbeats:

```toml
[scout.rabbitmq]
enabled = true
url = "amqp://scout:CHANGE_ME@rabbitmq.example.internal:5672"

[scout.agent]
enabled = true
id = "scout-agent-edge-01"
region = "local"
heartbeat_interval_ms = 10000
capacity = 16
browser_instances = 2
page_concurrency = 16
lightpanda_path = "/usr/local/bin/lightpanda-docker"
```

`lightpanda_path` must be one executable path, not a full shell command. For Docker-based Lightpanda, install a wrapper on the Scout agent host:

```bash
sudo tee /usr/local/bin/lightpanda-docker >/dev/null <<'SH'
#!/usr/bin/env bash
set -euo pipefail

exec docker run --pull=never --rm --network host lightpanda/browser:nightly lightpanda "$@"
SH
sudo chmod +x /usr/local/bin/lightpanda-docker
docker pull lightpanda/browser:nightly
```

The `--network host` flag is needed because the Scout agent serves a temporary local page on `127.0.0.1` before Lightpanda renders it.

## Deploy The Umbrella App

### Tarball Release

```bash
VERSION=5.6.0
sudo mkdir -p /opt/gsmlg /etc/gsmlg /var/lib/mnesia /var/log/gsmlg
sudo install -d -o root -g gsmlg -m 0750 /etc/gsmlg/proxy-rules
sudo install -d -o gsmlg -g gsmlg -m 0750 /var/lib/gsmlg/proxy-rules
curl -L -o /tmp/gsmlg.tar.gz \
  "https://github.com/gsmlg-dev/gsmlg_umbrella/releases/download/v${VERSION}/gsmlg.tar.gz"
sudo tar -xzf /tmp/gsmlg.tar.gz -C /opt/gsmlg
sudo install -m 600 /path/to/gsmlg_umbrella.toml /etc/gsmlg/gsmlg_umbrella.toml
```

Run migrations before starting a new version:

```bash
sudo GSMLG_CONFIG_PATH=/etc/gsmlg/gsmlg_umbrella.toml \
  /opt/gsmlg/gsmlg/bin/gsmlg_umbrella eval "GSMLG.Release.migrate()"
```

Start the service:

```bash
sudo GSMLG_CONFIG_PATH=/etc/gsmlg/gsmlg_umbrella.toml \
  MNESIA_DIR=/var/lib/mnesia \
  MIX_BUN_PATH=/usr/bin/bun \
  BUN_SERVER_JS=/opt/gsmlg/gsmlg/lib/gsmlg_component-${VERSION}/priv/server.js \
  /opt/gsmlg/gsmlg/bin/gsmlg_umbrella start
```

### Docker Image

The Docker image runs only the umbrella app.

```bash
VERSION=5.6.0
docker pull "ghcr.io/gsmlg-dev/gsmlg-umbrella:v${VERSION}"

docker run -d \
  --name gsmlg_umbrella \
  --restart unless-stopped \
  -p 4110:4110 \
  -p 4111:4111 \
  -v /etc/gsmlg/gsmlg_umbrella.toml:/etc/gsmlg_umbrella.toml:ro \
  -v gsmlg-mnesia:/var/lib/mnesia \
  -v gsmlg-proxy-rules:/var/lib/gsmlg/proxy-rules \
  -e GSMLG_CONFIG_PATH=/etc/gsmlg_umbrella.toml \
  -e MNESIA_DIR=/var/lib/mnesia \
  "ghcr.io/gsmlg-dev/gsmlg-umbrella:v${VERSION}"
```

Run migrations with the same image and config:

```bash
docker run --rm \
  -v /etc/gsmlg/gsmlg_umbrella.toml:/etc/gsmlg_umbrella.toml:ro \
  -e GSMLG_CONFIG_PATH=/etc/gsmlg_umbrella.toml \
  "ghcr.io/gsmlg-dev/gsmlg-umbrella:v${VERSION}" \
  /app/bin/gsmlg_umbrella eval "GSMLG.Release.migrate()"
```

## Deploy Commander

```bash
VERSION=5.6.0
TARGET=linux-amd64
sudo mkdir -p /opt/gsmlg
curl -L -o "/tmp/commander-${TARGET}.tar.gz" \
  "https://github.com/gsmlg-dev/gsmlg_umbrella/releases/download/v${VERSION}/commander-${TARGET}.tar.gz"
sudo tar -xzf "/tmp/commander-${TARGET}.tar.gz" -C /opt/gsmlg
mkdir -p ~/.config/gsmlg/commander
install -m 600 /path/to/config.toml ~/.config/gsmlg/commander/config.toml

/opt/gsmlg/commander/bin/gsmlg_commander start
```

Expected result:

- The worker opens an outbound WebSocket derived from `umbrella_server_url`.
- The admin UI can show the Commander under `/commander`.
- No inbound firewall rule is required for the Commander worker.

## Deploy Scout Agent

```bash
VERSION=5.6.0
sudo mkdir -p /opt/gsmlg /etc/gsmlg
curl -L -o /tmp/gsmlg_scout_agent.tar.gz \
  "https://github.com/gsmlg-dev/gsmlg_umbrella/releases/download/v${VERSION}/gsmlg_scout_agent.tar.gz"
sudo tar -xzf /tmp/gsmlg_scout_agent.tar.gz -C /opt/gsmlg
sudo install -m 600 /path/to/gsmlg_scout_agent.toml /etc/gsmlg/gsmlg_scout_agent.toml

sudo GSMLG_CONFIG_PATH=/etc/gsmlg/gsmlg_scout_agent.toml \
  /opt/gsmlg/gsmlg_scout_agent/bin/gsmlg_scout_agent start
```

Expected result:

- The agent publishes heartbeats to `scout.agent.heartbeat`.
- RabbitMQ shows a consumer on `scout.fetch.jobs`.
- The admin Scout page shows the agent.
- Fetch jobs complete when Lightpanda is available.

## systemd Units

Use separate units per role. Adjust paths and users for the target host.

### Umbrella

```ini
[Unit]
Description=GSMLG Umbrella
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
User=gsmlg
WorkingDirectory=/opt/gsmlg/gsmlg
Environment=GSMLG_CONFIG_PATH=/etc/gsmlg/gsmlg_umbrella.toml
Environment=MNESIA_DIR=/var/lib/mnesia
Environment=MIX_BUN_PATH=/usr/bin/bun
Environment=BUN_SERVER_JS=/opt/gsmlg/gsmlg/lib/gsmlg_component-5.6.0/priv/server.js
ConfigurationDirectory=gsmlg/proxy-rules
StateDirectory=gsmlg/proxy-rules
ExecStart=/opt/gsmlg/gsmlg/bin/gsmlg_umbrella start
ExecStop=/opt/gsmlg/gsmlg/bin/gsmlg_umbrella stop
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### Commander

```ini
[Unit]
Description=GSMLG Commander
After=network-online.target
Wants=network-online.target

[Service]
User=gsmlg
WorkingDirectory=/opt/gsmlg/commander
ExecStart=/opt/gsmlg/commander/bin/gsmlg_commander start
ExecStop=/opt/gsmlg/commander/bin/gsmlg_commander stop
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### Scout Agent

```ini
[Unit]
Description=GSMLG Scout Agent
After=network-online.target docker.service
Wants=network-online.target

[Service]
User=gsmlg
WorkingDirectory=/opt/gsmlg/gsmlg_scout_agent
Environment=GSMLG_CONFIG_PATH=/etc/gsmlg/gsmlg_scout_agent.toml
ExecStart=/opt/gsmlg/gsmlg_scout_agent/bin/gsmlg_scout_agent start
ExecStop=/opt/gsmlg/gsmlg_scout_agent/bin/gsmlg_scout_agent stop
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Enable and start a unit:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now gsmlg-umbrella.service
sudo systemctl status gsmlg-umbrella.service
```

## Post-Deploy Checks

Umbrella:

```bash
curl -fsS http://127.0.0.1:4110/
curl -fsS http://127.0.0.1:4111/
test "$(curl --fail --silent --show-error --dump-header /tmp/proxy-rules.headers \
  --write-out '%{http_code}' \
  http://127.0.0.1:4110/api/proxy-rules/proxy-list/raw \
  --output /tmp/proxy-list.raw)" = 200
etag=$(awk 'BEGIN {IGNORECASE=1} /^etag:/ {sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print}' /tmp/proxy-rules.headers)
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --header "If-None-Match: ${etag}" \
  http://127.0.0.1:4110/api/proxy-rules/proxy-list/raw)" = 304
```

Commander:

```bash
journalctl -u gsmlg-commander.service -f
```

Check the admin UI under `/commander`.

Scout agent:

```bash
journalctl -u gsmlg-scout-agent.service -f
rabbitmqctl list_queues name consumers messages | grep scout
```

Check the admin UI under `/scout` and submit a fetch job for `https://example.com/`.

## Rollback

Keep the previous release directory or tarball on each host. To roll back:

1. Stop the affected systemd unit.
2. Restore the previous release directory or retarget the symlink used by the unit.
3. Restart the unit.
4. If a database migration must be reverted, use the release rollback helper with the target migration version:

```bash
/opt/gsmlg/gsmlg/bin/gsmlg_umbrella eval \
  "GSMLG.Release.rollback(GSMLG.Repo, 20231001000000)"
```
