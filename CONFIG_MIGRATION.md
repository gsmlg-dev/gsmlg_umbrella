# Configuration System Migration Guide

## Overview

This document describes the migration from the old gsmlg_toml + gsmlg_config architecture to the new unified configuration system.

## What Changed

### Architecture

**Before:**
- Separate `gsmlg_toml` app for TOML parsing
- `gsmlg_config` app with Agent-based runtime state
- Configuration loaded in Application.start/2
- Single `gsmlg.toml` file

**After:**
- TOML parser integrated into `gsmlg_config`
- No Agent - configuration stored in Application environment
- Configuration loaded via `config/runtime.exs` before app starts
- Layered configuration with environment-specific files

### Configuration Files

New configuration structure:
```
config/
├── base.toml              # Base defaults for all environments
├── dev.toml               # Development overrides
├── test.toml              # Test environment settings
├── prod.toml              # Production settings
└── local.toml             # Local overrides (gitignored)
```

### Loading Order

Configuration layers are merged in precedence order:
1. `config/base.toml` - Base defaults
2. `config/{env}.toml` - Environment-specific (dev/test/prod)
3. `config/local.toml` - Local overrides (optional, not in git)
4. `GSMLG_*` environment variables - Runtime overrides

### New Features

1. **Environment Variable Overrides**
   ```bash
   # Override nested config with double underscore
   GSMLG_DATABASE__HOSTNAME=db.example.com
   GSMLG_WEB__PORT=8080
   ```

2. **Schema Validation**
   - Configuration is validated against NimbleOptions schema
   - Type coercion (strings → integers, booleans)
   - Required field checking
   - Helpful error messages

3. **Hot Reload (Development)**
   ```elixir
   # Reload config without restart
   GSMLG.Config.reload()
   ```

4. **Validation API**
   ```elixir
   # Check if config is valid
   {:ok, config} = GSMLG.Config.validate()
   ```

## API Changes

### GSMLG.Config

**Unchanged:**
```elixir
# These APIs remain the same
GSMLG.Config.config()
GSMLG.Config.get(:database)
GSMLG.Config.get([:database, :hostname])
```

**Removed:**
```elixir
# Agent-based updates are removed
GSMLG.Config.put(:key, value)  # REMOVED
```

**New:**
```elixir
# New validation and reload APIs
GSMLG.Config.validate()
GSMLG.Config.reload()
GSMLG.Config.config_path(:dev)
```

## Migration Steps

### 1. Remove Old gsmlg_toml App

```bash
# Remove the gsmlg_toml application directory
rm -rf apps/gsmlg_toml

# Clean build artifacts
mix clean
```

### 2. Update Configuration Files

Split your existing `gsmlg.toml` into the new structure:

```bash
# Base configuration (config/base.toml)
# - Common defaults for all environments
# - Non-secret values only

# Environment configs (config/{env}.toml)
# - dev.toml: Development-specific settings
# - test.toml: Test environment settings
# - prod.toml: Production settings (no secrets!)

# Local config (config/local.toml) - gitignored
# - Local development overrides
# - Secrets for development
```

### 3. Update Dependencies

Already done in umbrella mix.exs files:
- ✅ Removed `{:gsmlg_toml, in_umbrella: true}` from apps
- ✅ Added `{:nimble_options, "~> 1.0"}` to gsmlg_config
- ✅ Added `{:gsmlg_telemetry, in_umbrella: true}` to gsmlg_config

### 4. Test Configuration

```elixir
# Start IEx and check config
iex -S mix

# View loaded config
GSMLG.Config.config()

# Check specific values
GSMLG.Config.get([:database, :hostname])
GSMLG.Config.get(:web)

# Validate configuration
GSMLG.Config.validate!()
```

### 5. Update Environment Variables (Production)

Use the new `GSMLG_*` prefix for environment variables:

```bash
# Old way (if you used env vars)
DATABASE_HOST=db.example.com

# New way
GSMLG_DATABASE__HOSTNAME=db.example.com
GSMLG_DATABASE__PORT=3306
GSMLG_WEB__SECRET_KEY_BASE=your_secret_key
```

## Benefits

### Performance
- ✅ No Agent overhead - direct Application.get_env/2 calls
- ✅ Configuration loaded once at startup
- ✅ Zero runtime parsing in production

### Maintainability
- ✅ Environment-specific configs are explicit
- ✅ Schema validation catches errors early
- ✅ Clear separation of concerns
- ✅ Better error messages

### Flexibility
- ✅ Layer-based configuration merging
- ✅ Environment variable overrides
- ✅ Hot reload in development
- ✅ Validation API

### Best Practices
- ✅ Follows Elixir 1.9+ runtime.exs pattern
- ✅ Works seamlessly with OTP releases
- ✅ Supports 12-factor app principles
- ✅ Clear secret management strategy

## Troubleshooting

### Config Not Loading

**Issue:** Configuration is empty or shows warning
```elixir
GSMLG.Config.config()  # => %{}
```

**Solution:** Check that config files exist and runtime.exs can load them:
```bash
ls -la config/*.toml
cat config/runtime.exs
```

### Validation Errors

**Issue:** Application fails to start with validation error

**Solution:** Check the error message for details:
```bash
mix run --no-start -e "GSMLG.Config.Loader.load!()"
```

### Environment Variables Not Working

**Issue:** `GSMLG_*` environment variables not applied

**Solution:** Check variable naming:
- Use `GSMLG_` prefix
- Use double underscore `__` for nesting
- Example: `GSMLG_DATABASE__HOSTNAME` not `GSMLG_DATABASE_HOSTNAME`

### Toml Module Conflicts

**Issue:** "redefining module Toml.Error" warning

**Solution:** Remove the old `apps/gsmlg_toml` directory completely:
```bash
rm -rf apps/gsmlg_toml
mix clean
mix deps.clean --all
mix deps.get
mix compile
```

## File Structure Reference

```
apps/gsmlg_config/
├── lib/
│   ├── gsmlg/
│   │   └── config/
│   │       ├── application.ex      # Empty supervision tree
│   │       ├── loader.ex           # Layered config loading
│   │       ├── schema.ex           # NimbleOptions validation
│   │       ├── setup.ex            # Apply config to apps (unchanged)
│   │       └── transforms.ex       # Value transformation pipeline
│   ├── gsmlg/
│   │   └── config.ex               # Main API (no Agent)
│   ├── toml.ex                     # TOML parser (moved from gsmlg_toml)
│   ├── decoder.ex
│   ├── lexer.ex
│   ├── provider.ex
│   ├── transform.ex
│   └── ...                         # Other TOML modules
└── mix.exs

config/
├── base.toml                       # Base configuration
├── dev.toml                        # Development config
├── test.toml                       # Test config
├── prod.toml                       # Production config
├── local.toml                      # Local overrides (gitignored)
├── .gitignore                      # Ignore local.toml
└── runtime.exs                     # Loads layered config
```

## Next Steps

1. **Remove gsmlg_toml directory:**
   ```bash
   rm -rf apps/gsmlg_toml
   ```

2. **Clean and recompile:**
   ```bash
   mix clean
   mix deps.clean --all
   mix compile
   ```

3. **Test configuration:**
   ```bash
   MIX_ENV=test mix run -e "GSMLG.Config.validate!()"
   ```

4. **Update CI/CD:**
   - Update deployment scripts to use new config structure
   - Set `GSMLG_*` environment variables
   - Remove references to old gsmlg.toml file

5. **Update documentation:**
   - Update deployment guides
   - Document new configuration options
   - Add examples for production deployment

## Support

For issues or questions:
- Check this migration guide
- Review `apps/gsmlg_config/lib/gsmlg/config.ex` for API
- Review `config/base.toml` for configuration structure
- Check git history for examples
