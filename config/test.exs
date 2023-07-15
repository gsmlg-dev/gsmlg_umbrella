import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :gsmlg, GSMLG.Repo,
  username: "gsmlg_test",
  password: "gsmlg_test",
  database: "gsmlg_test#{System.get_env("MIX_TEST_PARTITION")}",
  hostname: "mariadb-server.gsmlg.net",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :gsmlg_web, GSMLGWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4112],
  server: false

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :gsmlg_admin_web, GSMLGAdminWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4113],
  server: false

# Print only warnings and errors during test
config :logger, level: :warn

# In test we don't send emails.
config :gsmlg, GSMLG.Mailer, adapter: Swoosh.Adapters.Test

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
