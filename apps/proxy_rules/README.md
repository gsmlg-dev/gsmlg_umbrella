# Proxy Rules

`proxy_rules` compiles the official GFWList together with optional local
overrides into immutable raw, Squid, and Clash artifacts. It is part of the
umbrella release; it does not run a separate endpoint or release.

## Configuration

Configure the service in the `[proxy_rules]` section of the TOML file selected
by `GSMLG_CONFIG_PATH`.

| Key | Default | Purpose |
| --- | --- | --- |
| `source_url` | `https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt` | Official Base64-encoded GFWList URL. |
| `remote_refresh_interval` | `86400000` | Successful remote refresh interval in milliseconds. |
| `remote_connect_timeout` | `5000` | Remote connection timeout in milliseconds. |
| `remote_receive_timeout` | `30000` | Remote response timeout in milliseconds. |
| `remote_max_body_size` | `10000000` | Maximum encoded response body in bytes; the implementation rejects values above 64 MiB. |
| `retry_min_interval` | `5000` | Initial/minimum retry delay in milliseconds. |
| `retry_max_interval` | `300000` | Maximum retry delay in milliseconds. |
| `retry_jitter` | `true` | Randomize retry delays to avoid synchronized fetches. |
| `local_proxy_list_path` | `/etc/gsmlg/proxy-rules/proxy-list.txt` | Optional local proxy-domain file. |
| `local_direct_list_path` | `/etc/gsmlg/proxy-rules/direct-list.txt` | Optional local direct-domain file. |
| `local_watch_debounce` | `500` | Filesystem-event debounce in milliseconds. |
| `local_reconciliation_interval` | `60000` | Periodic local-file reconciliation interval in milliseconds. |
| `state_directory` | `/var/lib/gsmlg/proxy-rules` | Durable last-known-good remote and artifact state. |
| `cache_control` | `public, max-age=3600` | `Cache-Control` header returned with public artifacts. |
| `unsupported_rule_sample_limit` | `20` | Maximum diagnostic samples retained; counts remain complete. |

The shared configuration parent must be readable but not writable by the
service user. Give the release service identity a dedicated Local proxy
subdirectory so it can create the sibling temporary file required for atomic
replacement. Keep Local direct in a separate operator-owned subdirectory.
proxy-list.txt must be writable by the release service identity so the
authenticated admin can atomically add domains.
direct-list.txt remains operator-owned and read-only to the release service identity.
Neither file should be writable by an untrusted account. The state directory
must be private and read/write for the service user. A typical host setup is:

```bash
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

if [ -L "$direct_dir" ] || { [ -e "$direct_dir" ] && [ ! -d "$direct_dir" ]; }; then
  echo "Manual repair required: Local direct directory is a symlink or non-directory" >&2
  exit 1
fi
sudo install -d -o root -g gsmlg -m 0750 -- "$direct_dir"

if [ -L "$legacy_direct" ] || { [ -e "$legacy_direct" ] && [ ! -f "$legacy_direct" ]; }; then
  echo "Manual repair required: legacy Local direct source is a symlink or non-regular" >&2
  exit 1
fi
if [ -L "$direct_target" ] || { [ -e "$direct_target" ] && [ ! -f "$direct_target" ]; }; then
  echo "Manual repair required: Local direct source is a symlink or non-regular" >&2
  exit 1
fi
if [ -e "$legacy_direct" ] && [ -e "$direct_target" ]; then
  echo "Manual conflict: both legacy and separated Local direct sources exist" >&2
  exit 1
fi
if [ ! -e "$direct_target" ]; then
  if [ -e "$legacy_direct" ]; then
    sudo mv -- "$legacy_direct" "$direct_target"
  else
    sudo install -o root -g gsmlg -m 0640 /dev/null "$direct_target"
  fi
fi
sudo chown root:gsmlg -- "$direct_target"
sudo chmod 0640 -- "$direct_target"
)
```

These commands are safe to repeat during upgrades. If both a legacy source and
its separated destination exist, they leave both untouched so an operator can
resolve the conflict without losing rules. Existing service-writable Local
proxy directories are validation-only: never run privileged `chown`, `chmod`,
copy, or move operations on their entries. Stop the service and rebuild an
unsafe directory from root-controlled staging when manual repair is required.
The repeat-deployment branch only probes, as `gsmlg`, that the directory is
searchable/writable and the source is readable/writable.

Point the service at those separated source paths:

```toml
[proxy_rules]
local_proxy_list_path = "/etc/gsmlg/proxy-rules/proxy/proxy-list.txt"
local_direct_list_path = "/etc/gsmlg/proxy-rules/direct/direct-list.txt"
```

Each local file contains one domain per line. Blank lines and lines beginning
with `#` or `!` are ignored. A leading suffix dot and trailing DNS root dot are
accepted. URLs, GFWList/Adblock syntax, wildcards, regular expressions, IP
literals, and CIDRs are not accepted in local files. Missing files are valid
empty sources on first startup; after a valid read, a temporary disappearance
retains the last valid snapshot.

## Authenticated Admin Source Management

The `/proxy-rules` admin page can add domains only to the configured local
proxy source. The admin textarea accepts bare domains only, one per line. It
rejects URLs, comments, wildcards, regular expressions, IP addresses, CIDRs,
and arbitrary GFWList syntax. Validation is atomic: if any non-empty line is
invalid, no domains are written. Valid domains are canonicalized, and
duplicates are automatically omitted both within the submission and against
the current source.

Admin-added entries are stored as canonical bare domains. Existing semantic
entries and comments are retained, while mutation normalizes line endings,
trailing spaces, and trailing blank lines. Renderers normalize parsed rules for
Raw/DNS, Squid, and Clash output. Raw/DNS emits `baidu.com`, Squid emits
`.baidu.com`, and Clash emits `DOMAIN-SUFFIX,baidu.com`.

GFWList content is decoded, lazy-loaded, authenticated, and virtualized. The
viewer does not fetch GFWList content during the initial page render and keeps
only a bounded set of visible rows in the DOM. Authenticated administrators can
also view the validated Local proxy source. Local direct remains outside the
admin interface: it cannot be viewed or edited.

## Startup, Refresh, and Diagnosis

On startup, the service validates and restores last-known-good source and
artifact snapshots from `state_directory`. A restored artifact is served as
`stale` until the remote source is successfully validated with a `200` or
`304` response. Corrupt or incomplete persisted state is rejected without
publishing a partial generation.

Use the authenticated admin page at `/proxy-rules` to inspect source
availability, generation metadata, bounded diagnostics, and the last
operational error. The page's **Refresh remote source** action requests an
asynchronous refresh; equivalent release-console code is:

```elixir
GSMLG.ProxyRules.refresh()
```

`ready` means the current artifact and all source freshness checks are healthy.
`refreshing` means a remote request is active. `stale` means the last-known-good
artifact is still available but a source, compilation, or persistence operation
failed. `not_ready` means no complete artifact has ever been published. When
stale, inspect the source cards and `operational_status`/`last_error`, verify
network access and local-file permissions, then refresh. A failed refresh never
replaces the last-known-good generation.

## Public Artifacts and Caching

The public endpoint exposes exactly these paths:

```text
/api/proxy-rules/proxy-list/raw
/api/proxy-rules/proxy-list/squid
/api/proxy-rules/proxy-list/clash
/api/proxy-rules/direct-list/raw
/api/proxy-rules/direct-list/squid
/api/proxy-rules/direct-list/clash
```

Successful responses include `ETag`, `Last-Modified`, `Cache-Control`, and
`X-Proxy-Rules-Generation`. Revalidate a cached artifact with `If-None-Match`;
an unchanged artifact returns `304` without a response body:

```bash
curl --fail --dump-header /tmp/proxy-rules.headers \
  http://127.0.0.1:4110/api/proxy-rules/proxy-list/raw \
  --output /tmp/proxy-list.raw
etag=$(awk 'BEGIN {IGNORECASE=1} /^etag:/ {sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print}' /tmp/proxy-rules.headers)
curl --fail --header "If-None-Match: ${etag}" \
  http://127.0.0.1:4110/api/proxy-rules/proxy-list/raw \
  --output /dev/null
```

Configure gateways to evaluate the direct list before the proxy list. The
compiler deliberately preserves domains present in both lists so that this
downstream order resolves conflicts toward direct routing.

## Benchmark

The benchmark uses the vendored official fixture, empty local files, the real
compiler, and 100,000 direct ETS reads. Pass an optional compile iteration
count:

```bash
devenv shell -- mix run --no-start apps/proxy_rules/bench/proxy_rules_benchmark.exs 5
```

It prints the fixture hash, accepted rule count, mean compile milliseconds,
total artifact bytes, lookup operations per second, OTP release, and Elixir
version. Record the host hardware alongside results when comparing runs.
