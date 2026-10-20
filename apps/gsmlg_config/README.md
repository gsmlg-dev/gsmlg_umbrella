# GSMLG.Config

Layered TOML configuration system for GSMLG applications with support for environment-specific configs, environment variable overrides, and custom config file paths.

## TOML dependency

TOML parsing is provided by the Hex package `gsmlg_toml` (`~> 1.0`). Its standalone
source and regression suite live in [`packages/gsmlg_toml`](../../packages/gsmlg_toml).
The parser is maintained outside the umbrella's `apps` directory so the umbrella
uses the same published dependency as other consumers.

Other packages that only need TOML parsing can depend on `gsmlg_toml` directly.
This application retains the GSMLG-specific loader, schema, transforms and setup.

## Features

- **TOML-based configuration** - Human-readable configuration format
- **Environment-specific configs** - Separate configs for dev, test, and prod
- **Environment variable overrides** - Override any config via `GSMLG_*` env vars
- **Custom config paths** - Specify config file via environment variable or command line
- **Deep merging** - Configuration layers are intelligently merged
- **Schema validation** - Ensures configuration correctness

## Configuration Path Priority

The configuration file is loaded from the first available source:

1. **Command line argument** (production releases only):
   ```bash
   ./bin/gsmlg_umbrella start --config=/etc/gsmlg/production.toml
   ```

2. **Environment variable**:
   ```bash
   export GSMLG_CONFIG_PATH=/etc/gsmlg/production.toml
   mix phx.server
   ```

3. **Programmatic option**:
   ```elixir
   GSMLG.Config.Loader.load(config_path: "/custom/config.toml")
   ```

4. **Default paths** (in order):
   - `apps/gsmlg_config/priv/gsmlg.{env}.toml` (e.g., `gsmlg.dev.toml`)
   - `apps/gsmlg_config/priv/gsmlg.toml` (fallback)

## Usage Examples

### Development (with Mix)

```bash
# Use default config for current environment
mix phx.server

# Use custom config file
GSMLG_CONFIG_PATH=/path/to/custom.toml mix phx.server
```

### Production (Release)

```bash
# Use default config
./bin/gsmlg_umbrella start

# Use custom config via command line
./bin/gsmlg_umbrella start --config=/etc/gsmlg/production.toml

# Use custom config via environment variable
GSMLG_CONFIG_PATH=/etc/gsmlg/production.toml ./bin/gsmlg_umbrella start
```

### Environment Variable Overrides

Override any configuration value using `GSMLG_*` environment variables with double underscores for nesting:

```bash
# Override database hostname
export GSMLG_DATABASE__HOSTNAME=db.production.com

# Override web port
export GSMLG_WEB__PORT=8080

# Start application with overrides
mix phx.server
```

## Configuration File Format

Configuration files use TOML format:

```toml
# gsmlg.toml

[database]
username = "gsmlg_user"
hostname = "localhost"
port = 3306

[web]
port = 4110
host = "localhost"

[admin_web]
port = 4111
```

## GaoNote Attachment Storage

Set the storage root for new GaoNote attachments in TOML:

```toml
[gao_note]
storage_path = "gaonote"
```

The default is `gaonote`. The value must be a nonempty single storage tenant/root
segment containing only letters, numbers, `_`, and `-`; nested paths are invalid.
New attachment keys use `<storage_path>/gao_note_attachment/YYYY/MM/uuid.ext`.
Changing this setting affects new uploads; existing files keep their stored keys
and remain accessible.

The same setting supports the generic environment override:

```bash
export GSMLG_GAO_NOTE__STORAGE_PATH=custom-notes
```

The GaoNote settings page can save this value to the exact TOML file selected at
startup and apply it immediately to new uploads. The file and its directory must
be writable by the application. Saving preserves other settings, comments, and
file ownership and permissions, and leaves the running configuration unchanged on failure.
An environment override takes priority and prevents saving through the UI;
remove it before editing the TOML-backed setting. The editor supports a regular
TOML file with a canonical `[gao_note]` table (or adds that table if absent).
Quoted/dotted GaoNote declarations and symlink files return an unsupported-format
error; symlinks in the containing directory are supported.

## Programmatic Usage

```elixir
# Load configuration
{:ok, config} = GSMLG.Config.Loader.load(env: :prod)

# Load with custom path
{:ok, config} = GSMLG.Config.Loader.load(
  config_path: "/etc/gsmlg/custom.toml",
  validate: true
)

# Load and raise on error
config = GSMLG.Config.Loader.load!(env: :prod)
```

## Installation

Add `gsmlg_config` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:gsmlg_config, "~> 0.1.0"}
  ]
end
```

