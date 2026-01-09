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

config_dir = Path.expand("../apps/gsmlg_config/priv", __DIR__)
env_config_file = Path.join(config_dir, "gsmlg.#{config_env()}.toml")
fallback_config_file = Path.join(config_dir, "gsmlg.toml")

# Check if at least one config file exists
has_config? =
  System.get_env("GSMLG_CONFIG_PATH") != nil or
    File.exists?(env_config_file) or
    File.exists?(fallback_config_file)

if Code.ensure_loaded?(GSMLG.Config.Loader) and has_config? do
  try do
    case GSMLG.Config.Loader.load(env: config_env()) do
      {:ok, gsmlg_config} ->
        # Store the loaded configuration for the application to access
        config :gsmlg_config, :loaded_config, gsmlg_config

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
  if Code.ensure_loaded?(GSMLG.Config.Loader) do
    IO.warn("No GSMLG configuration file found in #{config_dir}")
    IO.warn("Looked for: gsmlg.#{config_env()}.toml or gsmlg.toml")
    IO.warn("Using default configuration")
  end
end

if System.get_env("MIX_TAILWIND_PATH") do
  config :tailwind, path: System.get_env("MIX_TAILWIND_PATH")
end

mnesia_dir_default =
  Path.expand("../_build/tmp/mnesia/#{config_env()}/#{node()}", __DIR__)

# Configure Mnesia directory based on environment
mnesia_dir =
  case System.get_env("MNESIA_DIR") do
    nil -> mnesia_dir_default
    "" -> mnesia_dir_default
    dir -> dir
  end

config :mnesia, dir: String.to_charlist(mnesia_dir)

# Configure database for test environment from environment variables (for CI)
if config_env() == :test do
  if System.get_env("POSTGRES_HOST") do
    # Use Sandbox pool for tests, but standard pool for migrations
    # Set SKIP_SANDBOX_POOL=true for migrations to avoid lock issues
    # Must explicitly set pool: DBConnection.ConnectionPool to override any
    # Sandbox pool setting from test.exs (since Config deep merges)
    pool_config =
      if System.get_env("SKIP_SANDBOX_POOL") do
        [pool: DBConnection.ConnectionPool, pool_size: 10]
      else
        [pool: Ecto.Adapters.SQL.Sandbox, pool_size: 10]
      end

    config :gsmlg,
           GSMLG.Repo,
           Keyword.merge(
             [
               username: System.get_env("POSTGRES_USER", "gsmlg_test"),
               password: System.get_env("POSTGRES_PASSWORD", "gsmlg_test"),
               database:
                 System.get_env("POSTGRES_DB", "gsmlg_test") <>
                   "#{System.get_env("MIX_TEST_PARTITION")}",
               hostname: System.get_env("POSTGRES_HOST"),
               port: String.to_integer(System.get_env("POSTGRES_PORT", "5432"))
             ],
             pool_config
           )
  end
end

if config_env() == :prod do
  config :phoenix_react_server, Phoenix.React.Runtime.Bun,
    cmd: System.get_env("MIX_BUN_PATH", System.find_executable("bun")),
    server_js: System.get_env("BUN_SERVER_JS"),
    port: String.to_integer(System.get_env("BUN_PORT", "5252")),
    env: :prod
end
