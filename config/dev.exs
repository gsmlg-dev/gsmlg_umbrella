import Config

# Configure your database
# config :gsmlg, GSMLG.Repo,
#   username: "gsmlg_dev",
#   password: "gsmlg_dev",
#   database: "gsmlg_dev",
#   hostname: System.get_env("DB_HOST", "mariadb-server.gsmlg.net"),
#   show_sensitive_data_on_connection_error: true,
#   pool_size: 10
config :gsmlg, GSMLG.Repo,
  username: System.get_env("MARIADB_USER", "gsmlg_dev"),
  password: System.get_env("MARIADB_PASS", "gsmlg_dev"),
  hostname: System.get_env("MARIADB_HOST", "mariadb-server.gsmlg.net"),
  database: "gsmlg_dev",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# For development, we disable any cache and enable
# debugging and code reloading.
#
# The watchers configuration can be used to run external
# watchers to your application. For example, we use it
# with esbuild to bundle .js and .css sources.
config :gsmlg_web, GSMLGWeb.Endpoint,
  # Binding to loopback ipv4 address prevents access from other machines.
  # Change to `ip: {0, 0, 0, 0}` to allow access from other machines.
  http: [ip: {0, 0, 0, 0}, port: System.get_env("PORT", "4000") |> String.to_integer()],
  debug_errors: true,
  code_reloader: true,
  check_origin: false,
  watchers: [
    # Start the esbuild watcher by calling Esbuild.install_and_run(:default, args)
    tailwind: {Tailwind, :install_and_run, [:default, ~w(--watch)]},
    esbuild:
      {Esbuild, :install_and_run,
       [:default, ~w(--sourcemap=inline --watch --loader:.png=file --loader:.svg=file)]}
  ]

# Watch static and templates for browser reloading.
config :gsmlg_web, GSMLGWeb.Endpoint,
  live_reload: [
    patterns:
      [
        ~r"priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
        ~r"priv/gettext/.*(po)$",
        ~r"lib/gsmlg_web/(live|views)/.*(ex)$",
        ~r"lib/gsmlg_web/templates/.*(eex)$"
      ] ++
        [
          ~r"lib/gsmlg_yellow_dog/.*(ex)$",
          ~r"lib/gsmlg/.*(ex)$"
        ] ++
        if(System.get_env("WEBCOMPONENT_PATH"),
          do: [~r"#{System.get_env("WEBCOMPONENT_PATH")}/lib/.*(ex)$"],
          else: []
        )
  ]

# Do not include metadata nor timestamps in development logs
config :logger, :console, format: "[$level] $message\n"

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# config :amqp,
#   connections: [
#     bunny: [url: System.get_env("AMQP_URL", "amqp://guest:guest@localhost:5672")]
#   ],
#   channels: [
#     bunny: [connection: :bunny]
#   ]

config :gsmlg_couchdb, GSMLG_CouchDB.Connection,
  host: System.get_env("COUCH_HOST", "127.0.0.1"),
  port: 5984,
  username: System.get_env("COUCH_USER", "couch_user"),
  password: System.get_env("COUCH_PASS", "couch_pass")
