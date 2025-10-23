import Config

# Load GSMLG configuration from layered TOML files
# This happens before any applications start, ensuring configuration is available
# Configuration layers (in precedence order):
#   1. config/base.toml - Base defaults
#   2. config/{env}.toml - Environment-specific overrides
#   3. config/local.toml - Local overrides (optional, gitignored)
#   4. GSMLG_* environment variables - Runtime overrides

if Code.ensure_loaded?(GSMLG.Config.Loader) and File.exists?("config/base.toml") do
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
