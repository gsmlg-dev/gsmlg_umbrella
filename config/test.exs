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

config :web_push_encryption, :vapid_details,
  subject: "mailto:administrator@gsmlg.com",
  public_key: "BIkdbSFSsaW83HRGHxCjbspeLSWh-uLtGsKaF6SMniO-nezdWstXnKm8aIuM4vaFnxVGibz1OvtMCJi2cImQfxg",
  private_key: "waTKfV8CQpcUtwWgOYdNQcWbVAv-oWfAYk8Y70TduO8"
