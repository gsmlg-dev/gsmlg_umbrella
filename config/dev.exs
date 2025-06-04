import Config

# Configure your database
config :gsmlg, GSMLG.Repo,
  username: System.get_env("MARIADB_USER", "gsmlg_dev"),
  password: System.get_env("MARIADB_PASS", "gsmlg_dev"),
  hostname: System.get_env("MARIADB_HOST", "mariadb-server.gsmlg.net"),
  database: "gsmlg_dev",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :gsmlg_web, GSMLGWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: System.get_env("WEB_PORT", "4110") |> String.to_integer()],
  debug_errors: true,
  code_reloader: true,
  check_origin: false,
  watchers: [
    tailwind: {Tailwind, :install_and_run, [:gsmlg_web, ~w(--watch)]},
    bun: {Bun, :install_and_run, [:gsmlg_web, ~w(--sourcemap=inline --watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/gsmlg_component/.*(ex)$",
      ~r"lib/gsmlg_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :gsmlg_admin_web, GSMLGAdminWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: System.get_env("ADMIN_PORT", "4111") |> String.to_integer()],
  debug_errors: true,
  code_reloader: true,
  check_origin: false,
  watchers: [
    tailwind: {Tailwind, :install_and_run, [:gsmlg_admin_web, ~w(--watch)]},
    bun: {Bun, :install_and_run, [:gsmlg_admin_web, ~w(--sourcemap=inline --watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/gsmlg_component/.*(ex)$",
      ~r"lib/gsmlg_admin_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :gsmlg_admin_web, dev_routes: true

config :logger, level: :debug

config :phoenix, :plug_init_mode, :runtime

config :phoenix, :stacktrace_depth, 20

config :phoenix_live_view,
  debug_heex_annotations: true,
  enable_expensive_runtime_checks: true

config :gsmlg_couchdb, GSMLG.CouchDB.Connection,
  host: System.get_env("COUCH_HOST", "127.0.0.1"),
  port: 5984,
  username: System.get_env("COUCH_USER", "couch_user"),
  password: System.get_env("COUCH_PASS", "couch_pass")

config :phoenix_react_server, Phoenix.React,
  component_base: Path.expand("../apps/gsmlg_component/assets/component", __DIR__),
  cache_ttl: 5

config :phoenix_react_server, Phoenix.React.Runtime.Bun,
  cmd: System.find_executable("bun"),
  cd: Path.expand("../apps/gsmlg_component", __DIR__),
  server_js: Path.expand("../apps/gsmlg_component/priv/server.js", __DIR__),
  port: 4632,
  env: :dev

config :ueberauth, Ueberauth.Strategy.Github.OAuth,
  client_id: "Ov23liH40JTxHcLQYHAh",
  client_secret: "26932d3bebae9470e8d45043ae47a3559e94070a"
