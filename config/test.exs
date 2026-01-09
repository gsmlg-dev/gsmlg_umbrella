import Config

# Database configuration for tests
# Uses localhost by default for CI compatibility
# Set SKIP_SANDBOX_POOL=true for migrations to avoid Sandbox pool lock issues

pool_config =
  if System.get_env("SKIP_SANDBOX_POOL") do
    # Standard connection pool for migrations
    []
  else
    # Sandbox pool for running tests
    [pool: Ecto.Adapters.SQL.Sandbox]
  end

config :gsmlg,
       GSMLG.Repo,
       Keyword.merge(
         [
           username: "gsmlg_test",
           password: "gsmlg_test",
           database: "gsmlg_test#{System.get_env("MIX_TEST_PARTITION")}",
           hostname: "localhost",
           port: 5432,
           pool_size: 10
         ],
         pool_config
       )

config :gsmlg_web, GSMLG.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4112],
  server: false

config :gsmlg_admin_web, GSMLG.AdminWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4113],
  server: false

config :logger, level: :warning

# Configure Mnesia
config :mnesia,
  dir: ~c"priv/mnesia/test"

config :gsmlg, GSMLG.Mailer, adapter: Swoosh.Adapters.Test

config :phoenix, :plug_init_mode, :runtime

config :gsmlg_web_push, :vapid_details,
  subject: "mailto:administrator@gsmlg.com",
  public_key:
    "BIkdbSFSsaW83HRGHxCjbspeLSWh-uLtGsKaF6SMniO-nezdWstXnKm8aIuM4vaFnxVGibz1OvtMCJi2cImQfxg",
  private_key: "waTKfV8CQpcUtwWgOYdNQcWbVAv-oWfAYk8Y70TduO8"

config :phoenix_react_server, Phoenix.React,
  component_base: Path.expand("../apps/gsmlg_component/assets/component", __DIR__),
  cache_ttl: 0
