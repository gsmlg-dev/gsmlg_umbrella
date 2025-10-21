import Config

config :gsmlg_web, GSMLG.Web.Endpoint,
  url: [host: "gsmlg.org", port: 443, scheme: "https"],
  cache_static_manifest: "priv/static/cache_manifest.json"

config :gsmlg_admin_web, GSMLG.AdminWeb.Endpoint,
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

# Production telemetry configuration
config :gsmlg_telemetry,
  level: :info,
  backends: [
    console: [
      enabled: false
    ],
    file: [
      enabled: true,
      path: "/var/log/gsmlg/app.log",
      format: :json,
      max_file_size: 100 * 1024 * 1024,
      max_files: 10,
      compress: true,
      buffer_size: 500,
      flush_interval: 10_000
    ],
    cloudwatch: [
      enabled: true,
      log_group_name: "/gsmlg/production",
      log_stream_name: "#{node()}-#{System.get_env("HOSTNAME", "unknown")}",
      region: System.get_env("AWS_REGION", "us-east-1"),
      buffer_size: 500,
      flush_interval: 10_000,
      max_retries: 3
    ]
  ],
  report_interval: 60_000,
  max_buffer_size: 2000
