import Config

# Configure your database
pg_socket_ready? = fn socket_dir, port ->
  File.exists?(Path.join(socket_dir, ".s.PGSQL.#{port}"))
end

db_port = String.to_integer(System.get_env("PGPORT") || System.get_env("POSTGRES_PORT", "5432"))

# devenv exports DATABASE_URL + PGHOST, but PGHOST should only be used while
# the devenv Postgres service is actually running. Otherwise DATABASE_URL falls
# back to TCP host Postgres.
db_config =
  if url = System.get_env("DATABASE_URL") do
    [url: url]
  else
    [
      username: System.get_env("POSTGRES_USER", "gsmlg_dev"),
      password: System.get_env("POSTGRES_PASSWORD", "gsmlg_dev"),
      hostname: System.get_env("POSTGRES_HOST", "localhost"),
      port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
      database: "gsmlg_dev"
    ]
  end

# PGHOST set to an active socket path means Unix socket (devenv sets this automatically)
db_config =
  case System.get_env("PGHOST") do
    "/" <> _ = pghost ->
      if pg_socket_ready?.(pghost, db_port) do
        db_config
        |> Keyword.put(:socket_dir, pghost)
        |> Keyword.put(:port, db_port)
      else
        db_config
      end

    _ ->
      db_config
  end

db_config = db_config ++ [show_sensitive_data_on_connection_error: true, pool_size: 10]

config :gsmlg, GSMLG.Repo, db_config

config :gsmlg_web, GSMLG.Web.Endpoint,
  debug_errors: true,
  code_reloader: true,
  check_origin: false,
  watchers: [
    tailwind: {Tailwind, :install_and_run, [:gsmlg_web, ~w(--watch)]},
    bun: {Bun, :install_and_run, [:gsmlg_web, ~w(--sourcemap=inline --watch)]}
  ],
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/gsmlg_component/.*(ex)$",
      ~r"lib/gsmlg_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :gsmlg_admin_web, GSMLG.AdminWeb.Endpoint,
  debug_errors: true,
  code_reloader: true,
  check_origin: false,
  watchers: [
    tailwind: {Tailwind, :install_and_run, [:gsmlg_admin_web, ~w(--watch)]},
    bun: {Bun, :install_and_run, [:gsmlg_admin_web, ~w(--sourcemap=inline --watch)]}
  ],
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/gsmlg_component/.*(ex)$",
      ~r"lib/gsmlg_admin_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ],
  live_view: [
    signing_salt: "gmmaSSOy"
  ]

config :gsmlg_admin_web, dev_routes: true

config :logger, level: :debug

config :phoenix, :plug_init_mode, :runtime

config :phoenix, :stacktrace_depth, 20

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true

config :phoenix_react_server, Phoenix.React,
  component_base: Path.expand("../apps/gsmlg_component/assets/component", __DIR__),
  render_timeout: 30_000,
  cache_ttl: 5

config :phoenix_react_server, Phoenix.React.Runtime.Bun,
  cmd: System.find_executable("bun"),
  cd: Path.expand("../apps/gsmlg_component", __DIR__),
  server_js: Path.expand("../apps/gsmlg_component/priv/server.js", __DIR__),
  port: 4632,
  env: :dev

# Development-specific telemetry configuration
config :gsmlg_telemetry,
  level: :debug,
  backends: [
    console: [
      enabled: true,
      colored: true,
      show_events: false,
      show_metrics: true,
      level: :debug
    ],
    file: [
      enabled: false,
      path: "logs/gsmlg_dev.log",
      format: :json,
      max_file_size: 10 * 1024 * 1024,
      max_files: 3,
      compress: false,
      buffer_size: 50,
      flush_interval: 2_000
    ],
    cloudwatch: [
      enabled: false
    ]
  ],
  report_interval: 30_000

config :gsmlg, :api_provider_encryption_key, "gsmlg-umbrella-dev"
