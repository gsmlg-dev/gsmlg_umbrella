import Config

config :gsmlg, GSMLG.Repo,
  username: "gsmlg_test",
  password: "gsmlg_test",
  database: "gsmlg_test#{System.get_env("MIX_TEST_PARTITION")}",
  hostname: "mariadb-server.gsmlg.net",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :gsmlg_web, GSMLGWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4112],
  server: false

config :gsmlg_admin_web, GSMLGAdminWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4113],
  server: false

config :logger, level: :warning

config :gsmlg, GSMLG.Mailer, adapter: Swoosh.Adapters.Test

config :phoenix, :plug_init_mode, :runtime
