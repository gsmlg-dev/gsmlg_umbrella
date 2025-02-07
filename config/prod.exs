import Config

config :gsmlg_web, GSMLGWeb.Endpoint,
  url: [host: "gsmlg.org", port: 443, scheme: "https"],
  cache_static_manifest: "priv/static/cache_manifest.json"

config :gsmlg_admin_web, GSMLGAdminWeb.Endpoint,
  url: [host: "admin.gsmlg.org", port: 443, scheme: "https"],
  cache_static_manifest: "priv/static/cache_manifest.json"

# Configures Elixir's Logger
# Do not print debug messages in production
config :logger, :default_handler,
  level: :info,
  formatter: {GSMLG.Logger.Formatters.GsmlgNet, metadata: :all, planet: "gsmlg_umbrella"}

config :phoenix_react_server, Phoenix.React, cache_ttl: 1440

config :phoenix_react_server, Phoenix.React.Runtime.Bun,
  port: 4633,
  env: :prod
