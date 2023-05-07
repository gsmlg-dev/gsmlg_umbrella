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

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :livebook, LivebookWeb.Endpoint,
  http: [port: 4002],
  server: false

config :livebook, :iframe_port, 4003

# Disable authentication mode during test
config :livebook, :authentication_mode, :disabled

data_path = Path.expand("../_build/tmp/livebook_data/test", __DIR__)
# Clear data path for tests
if File.exists?(data_path) do
  File.rm_rf!(data_path)
end

config :livebook, :data_path, data_path

# Feature flags
config :livebook, :feature_flags, create_hub: true

# Use longnames when running tests in CI, so that no host resolution is required,
# see https://github.com/livebook-dev/livebook/pull/173#issuecomment-819468549
if System.get_env("CI") == "true" do
  config :livebook, :node, {:longnames, :"livebook@127.0.0.1"}
end
