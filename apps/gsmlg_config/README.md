# GSMLG.Config

Layered TOML configuration system for GSMLG applications with support for environment-specific configs, environment variable overrides, and custom config file paths.

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

