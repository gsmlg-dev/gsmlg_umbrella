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

[proxy_rules]
local_proxy_list_path = "/etc/gsmlg/proxy-rules/proxy/proxy-list.txt"
local_direct_list_path = "/etc/gsmlg/proxy-rules/direct/direct-list.txt"

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

Separate Local proxy and Local direct target directories are recommended. Both
must be searchable and writable by the release service identity, and both target
files must be readable and writable by that identity. This permits
same-directory temporary-file creation and atomic rename without making either
source writable by untrusted users.

```bash
VERSION=5.6.0
if ! getent group gsmlg >/dev/null; then
  sudo groupadd --system gsmlg
fi
if ! id -u gsmlg >/dev/null 2>&1; then
  sudo useradd --system --gid gsmlg --home-dir /opt/gsmlg \
    --shell /usr/sbin/nologin gsmlg
fi
sudo mkdir -p /opt/gsmlg
sudo install -d -o gsmlg -g gsmlg -m 0750 /var/lib/mnesia /var/log/gsmlg
sudo install -d -o root -g gsmlg -m 0750 /etc/gsmlg
# Stop the service before provisioning or migration.
if systemctl is-active --quiet gsmlg-umbrella.service; then
  sudo systemctl stop gsmlg-umbrella.service
fi

(
set -eu
proxy_root=/etc/gsmlg/proxy-rules
proxy_dir="$proxy_root/proxy"
proxy_target="$proxy_dir/proxy-list.txt"
legacy_proxy="$proxy_root/proxy-list.txt"
direct_dir="$proxy_root/direct"
direct_target="$direct_dir/direct-list.txt"
legacy_direct="$proxy_root/direct-list.txt"

sudo install -d -o root -g gsmlg -m 0750 -- "$proxy_root"
sudo install -d -o gsmlg -g gsmlg -m 0750 /var/lib/gsmlg/proxy-rules

if [ -L "$proxy_dir" ]; then
  echo "Manual repair required: Local proxy directory is a symlink" >&2
  exit 1
elif [ ! -e "$proxy_dir" ]; then
  # Initial provisioning: keep the directory root-controlled until the target is safe.
  sudo install -d -o root -g gsmlg -m 0750 -- "$proxy_dir"

  if [ -L "$legacy_proxy" ] || { [ -e "$legacy_proxy" ] && [ ! -f "$legacy_proxy" ]; }; then
    echo "Manual repair required: legacy Local proxy source is a symlink or non-regular" >&2
    exit 1
  fi

  if [ -e "$legacy_proxy" ]; then
    sudo mv -- "$legacy_proxy" "$proxy_target"
  else
    sudo install -o root -g root -m 0600 /dev/null "$proxy_target"
  fi

  if [ -L "$proxy_target" ] || [ ! -f "$proxy_target" ]; then
    echo "Manual repair required: Local proxy source is missing, a symlink, or non-regular" >&2
    exit 1
  fi

  sudo chown gsmlg:gsmlg -- "$proxy_target"
  sudo chmod 0640 -- "$proxy_target"
  sudo chown gsmlg:gsmlg -- "$proxy_dir"
  sudo chmod 0750 -- "$proxy_dir"
elif [ ! -d "$proxy_dir" ]; then
  echo "Manual repair required: Local proxy directory is non-regular" >&2
  exit 1
else
  # Existing service-writable directory: validation only; no privileged entry mutation.
  if [ -L "$proxy_target" ] || [ ! -f "$proxy_target" ]; then
    echo "Manual repair required: Local proxy source is missing, a symlink, or non-regular" >&2
    exit 1
  fi
  if [ -e "$legacy_proxy" ] || [ -L "$legacy_proxy" ]; then
    echo "Manual conflict: both legacy and separated Local proxy sources exist" >&2
    exit 1
  fi
  if ! sudo -u gsmlg sh -c '
    test -x "$1" &&
    test -w "$1" &&
    test -r "$2" &&
    test -w "$2"
  ' proxy-rules-permission-probe "$proxy_dir" "$proxy_target"; then
    echo "Manual repair required: Local proxy directory/source permissions do not allow gsmlg atomic replacement" >&2
    exit 1
  fi
fi

if [ -L "$direct_dir" ]; then
  echo "Manual repair required: Local direct directory is a symlink" >&2
  exit 1
elif [ ! -e "$direct_dir" ]; then
  # Initial provisioning: keep the directory root-controlled until the target is safe.
  sudo install -d -o root -g gsmlg -m 0750 -- "$direct_dir"

  if [ -L "$legacy_direct" ] || { [ -e "$legacy_direct" ] && [ ! -f "$legacy_direct" ]; }; then
    echo "Manual repair required: legacy Local direct source is a symlink or non-regular" >&2
    exit 1
  fi

  if [ -e "$legacy_direct" ]; then
    sudo mv -- "$legacy_direct" "$direct_target"
  else
    sudo install -o root -g root -m 0600 /dev/null "$direct_target"
  fi

  if [ -L "$direct_target" ] || [ ! -f "$direct_target" ]; then
    echo "Manual repair required: Local direct source is missing, a symlink, or non-regular" >&2
    exit 1
  fi

  sudo chown gsmlg:gsmlg -- "$direct_target"
  sudo chmod 0640 -- "$direct_target"
  sudo chown gsmlg:gsmlg -- "$direct_dir"
  sudo chmod 0750 -- "$direct_dir"
elif [ ! -d "$direct_dir" ]; then
  echo "Manual repair required: Local direct directory is non-regular" >&2
  exit 1
else
  # Existing service-writable directory: validation only; no privileged entry mutation.
  if [ -L "$direct_target" ] || [ ! -f "$direct_target" ]; then
    echo "Manual repair required: Local direct source is missing, a symlink, or non-regular" >&2
    exit 1
  fi
  if [ -e "$legacy_direct" ] || [ -L "$legacy_direct" ]; then
    echo "Manual conflict: both legacy and separated Local direct sources exist" >&2
    exit 1
  fi
  if ! sudo -u gsmlg sh -c '
    test -x "$1" &&
    test -w "$1" &&
    test -r "$2" &&
    test -w "$2"
  ' proxy-rules-permission-probe "$direct_dir" "$direct_target"; then
    echo "Manual repair required: Local direct directory/source permissions do not allow gsmlg atomic replacement" >&2
    exit 1
  fi
fi
)
curl -L -o /tmp/gsmlg.tar.gz \
  "https://github.com/gsmlg-dev/gsmlg_umbrella/releases/download/v${VERSION}/gsmlg.tar.gz"
sudo tar -xzf /tmp/gsmlg.tar.gz -C /opt/gsmlg
sudo install -o root -g gsmlg -m 0640 /path/to/gsmlg_umbrella.toml /etc/gsmlg/gsmlg_umbrella.toml
```

The guarded migration preserves existing legacy rules and never replaces an
already-migrated destination. The `/dev/null` installs run only for first
provisioning. Existing service-writable local source directories are
validation-only: do not run privileged `chown`, `chmod`, copy, or move
operations on their entries. Stop the service and rebuild an unsafe directory
from root-controlled staging when manual repair is required. The
repeat-deployment branches probe, as `gsmlg`, that each directory is
searchable/writable and each source is readable/writable.

Stop the service before replacing either source externally, or otherwise
serialize the edit with admin mutations. This prevents an external edit and an
admin submission from overwriting each other. With the service stopped, replace
one target at a time:

```bash
if ! sudo systemctl stop gsmlg-umbrella.service; then
  echo "Cannot stop gsmlg-umbrella.service; replacement aborted" >&2
  exit 1
fi
target=/etc/gsmlg/proxy-rules/proxy/proxy-list.txt # or the configured direct-list target
source=/path/to/updated-list.txt
if sudo sh -c '
  set -eu
  source=$1
  target=$2
  if [ -L "$target" ] || [ ! -f "$target" ]; then
    echo "Replacement target is a symlink or non-regular file" >&2
    exit 1
  fi
  owner_uid=$(stat -c %u -- "$target")
  group_gid=$(stat -c %g -- "$target")
  mode=$(stat -c %a -- "$target")
  target_dir=${target%/*}
  tmp=$(mktemp -- "$target_dir/.proxy-rules.external.XXXXXX")
  cleanup() { rm -f -- "$tmp"; }
  trap cleanup EXIT HUP INT TERM
  cat -- "$source" >"$tmp"
  chown "$owner_uid:$group_gid" -- "$tmp"
  chmod "$mode" -- "$tmp"
  mv -fT -- "$tmp" "$target"
  trap - EXIT HUP INT TERM
' proxy-rules-external-update "$source" "$target"; then
  sudo systemctl start gsmlg-umbrella.service
else
  echo "Replacement failed; service remains stopped" >&2
fi
```

The recipe preserves the target's numeric owner UID, group GID, and permission
mode. The provisioning preflight already guarantees that the preserved metadata
lets the `gsmlg` service identity read and write the target. The guarded `sudo`
block is needed to access protected source directories and restore arbitrary
numeric ownership; no privileged operation runs before the service is confirmed
stopped. Do not restart the service until the rename completes successfully.

Run migrations before starting a new version:

```bash
sudo --user=gsmlg --group=gsmlg -- \
  env GSMLG_CONFIG_PATH=/etc/gsmlg/gsmlg_umbrella.toml \
  /opt/gsmlg/gsmlg/bin/gsmlg_umbrella eval "GSMLG.Release.migrate()"
```

Start the service:

```bash
sudo --user=gsmlg --group=gsmlg -- \
  env GSMLG_CONFIG_PATH=/etc/gsmlg/gsmlg_umbrella.toml \
  MNESIA_DIR=/var/lib/mnesia MIX_BUN_PATH=/usr/bin/bun \
  BUN_SERVER_JS=/opt/gsmlg/gsmlg/lib/gsmlg_component-${VERSION}/priv/server.js \
  /opt/gsmlg/gsmlg/bin/gsmlg_umbrella start
```

### Docker Image

The Docker image runs only the umbrella app. Keep its source mounts aligned
with the `[proxy_rules]` paths above:

- Mount both configured local source directories read/write so same-directory
  temporary-file creation and atomic rename can succeed.
- Do not make either source writable by untrusted users.
- Do not mount the shared `/etc/gsmlg/proxy-rules` parent read/write.

The current Docker images do not set `USER`, so the release runs as root in the
container by default. The `gsmlg` ownership above applies to the tarball service.
If an operator supplies a non-root container user, that identity must be able to
create and rename sibling files and read/write the target in both local source
mounts; both mount modes remain read/write.

```bash
VERSION=5.6.0
docker pull "ghcr.io/gsmlg-dev/gsmlg-umbrella:v${VERSION}"

docker run -d \
  --name gsmlg_umbrella \
  --restart unless-stopped \
  -p 4110:4110 \
  -p 4111:4111 \
  -v /etc/gsmlg/gsmlg_umbrella.toml:/etc/gsmlg_umbrella.toml:ro \
  -v /etc/gsmlg/proxy-rules/proxy:/etc/gsmlg/proxy-rules/proxy \
  -v /etc/gsmlg/proxy-rules/direct:/etc/gsmlg/proxy-rules/direct \
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
sudo install -d -o gsmlg -g gsmlg -m 0700 /opt/gsmlg/.config/gsmlg/commander
sudo install -o gsmlg -g gsmlg -m 0600 /path/to/config.toml \
  /opt/gsmlg/.config/gsmlg/commander/config.toml

sudo --set-home --user=gsmlg --group=gsmlg -- \
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
sudo install -o root -g gsmlg -m 0640 /path/to/gsmlg_scout_agent.toml \
  /etc/gsmlg/gsmlg_scout_agent.toml

sudo --user=gsmlg --group=gsmlg -- \
  env GSMLG_CONFIG_PATH=/etc/gsmlg/gsmlg_scout_agent.toml \
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
ConfigurationDirectoryMode=0750
StateDirectory=gsmlg/proxy-rules
StateDirectoryMode=0750
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
