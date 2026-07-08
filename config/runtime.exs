import Config

# Load GSMLG configuration from TOML files
# This happens before any applications start, ensuring configuration is available
# Configuration sources (in precedence order):
#   1. GSMLG_CONFIG_PATH environment variable - Custom config file path
#   2. apps/gsmlg_config/priv/gsmlg.{env}.toml - Environment-specific config
#   3. apps/gsmlg_config/priv/gsmlg.toml - Fallback default config
#   4. GSMLG_* environment variables - Runtime overrides
#
# Example: GSMLG_CONFIG_PATH=/custom/config.toml mix phx.server

# Resolve config directory - works in both Mix and release environments
config_dir =
  case :code.priv_dir(:gsmlg_config) do
    {:error, _} ->
      # Fallback for Mix environment
      Path.expand("../apps/gsmlg_config/priv", __DIR__)

    priv_dir ->
      List.to_string(priv_dir)
  end

env_config_file = Path.join(config_dir, "gsmlg.#{config_env()}.toml")
fallback_config_file = Path.join(config_dir, "gsmlg.toml")

# Check if at least one config file exists
has_config? =
  System.get_env("GSMLG_CONFIG_PATH") != nil or
    File.exists?(env_config_file) or
    File.exists?(fallback_config_file)

# Skip GSMLG.Config loading entirely when SKIP_SANDBOX_POOL is set (for CI migrations)
# This avoids any interference with the database pool configuration
skip_config_loading? = System.get_env("SKIP_SANDBOX_POOL") != nil

if Code.ensure_loaded?(GSMLG.Config.Loader) and has_config? and not skip_config_loading? do
  try do
    case GSMLG.Config.Loader.load(env: config_env(), config_dir: config_dir) do
      {:ok, gsmlg_config} ->
        # Store the loaded configuration for the application to access
        config :gsmlg_config, :loaded_config, gsmlg_config

        if caddy_config = gsmlg_config[:caddy] do
          caddy_mode =
            case caddy_config[:mode] do
              "embedded" -> :embedded
              "external" -> :external
              mode when mode in [:embedded, :external] -> mode
              _ -> :external
            end

          config :caddy,
            start: caddy_config[:start] == true,
            mode: caddy_mode,
            admin_url: caddy_config[:admin_url],
            health_interval: caddy_config[:health_interval]
        end

        # Apply configuration via Setup module
        if Code.ensure_loaded?(GSMLG.Config.Setup) do
          GSMLG.Config.Setup.setup(gsmlg_config)
        end

      {:error, reason} ->
        IO.warn("Failed to load GSMLG configuration: #{inspect(reason)}")
        IO.warn("Using default configuration")
    end
  rescue
    e ->
      IO.warn("Error loading GSMLG configuration: #{inspect(e)}")
      IO.warn("Using default configuration")
  end
else
  if Code.ensure_loaded?(GSMLG.Config.Loader) and not skip_config_loading? do
    IO.warn("No GSMLG configuration file found in #{config_dir}")
    IO.warn("Looked for: gsmlg.#{config_env()}.toml or gsmlg.toml")
    IO.warn("Using default configuration")
  end
end

if key = System.get_env("GSMLG_API_PROVIDER_KEY") do
  config :gsmlg, :api_provider_encryption_key, key
end

if System.get_env("MIX_BUN_PATH") do
  config :bun, path: System.get_env("MIX_BUN_PATH")
end

if System.get_env("MIX_TAILWIND_PATH") do
  config :tailwind, path: System.get_env("MIX_TAILWIND_PATH")
end

if config_env() == :prod do
  config :phoenix_react_server, Phoenix.React.Runtime.Bun,
    cmd: System.get_env("MIX_BUN_PATH", System.find_executable("bun")),
    server_js: System.get_env("BUN_SERVER_JS"),
    port: String.to_integer(System.get_env("BUN_PORT", "5252")),
    env: :prod
end
