import Config

# Database configuration for tests
# devenv exports DATABASE_URL + PGHOST; CI sets POSTGRES_HOST for TCP
# Set SKIP_SANDBOX_POOL=true for migrations to avoid Sandbox pool lock issues

pool_opt =
  if System.get_env("SKIP_SANDBOX_POOL") do
    [pool: DBConnection.ConnectionPool]
  else
    [pool: Ecto.Adapters.SQL.Sandbox]
  end

test_db = System.get_env("POSTGRES_DB", "gsmlg_test") <> "#{System.get_env("MIX_TEST_PARTITION")}"

db_config =
  if url = System.get_env("DATABASE_URL") do
    # Replace dev database name with test database + partition
    test_url = String.replace(url, "gsmlg_dev", test_db)
    [url: test_url]
  else
    [
      username: System.get_env("POSTGRES_USER", "gsmlg_test"),
      password: System.get_env("POSTGRES_PASSWORD", "gsmlg_test"),
      hostname: System.get_env("POSTGRES_HOST", "localhost"),
      port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
      database: test_db
    ]
  end

# PGHOST set to a path means Unix socket (devenv sets this automatically)
db_config =
  case System.get_env("PGHOST") do
    "/" <> _ = pghost -> Keyword.put(db_config, :socket_dir, pghost)
    _ -> db_config
  end

db_config = db_config ++ [pool_size: 10]

config :gsmlg, GSMLG.Repo, Keyword.merge(db_config, pool_opt)

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

config :gsmlg, Oban, testing: :inline

config :gsmlg, :translation_provider, GSMLG.Translation.MockProvider

# Use Tesla.Mock as the HTTP adapter for ClaudeProvider in tests
config :gsmlg, :claude_tesla_adapter, Tesla.Mock

config :phoenix, :plug_init_mode, :runtime
config :phoenix, :sort_verified_routes_query_params, true

config :gsmlg_web_push, :vapid_details,
  subject: "mailto:administrator@gsmlg.com",
  public_key:
    "BIkdbSFSsaW83HRGHxCjbspeLSWh-uLtGsKaF6SMniO-nezdWstXnKm8aIuM4vaFnxVGibz1OvtMCJi2cImQfxg",
  private_key: "waTKfV8CQpcUtwWgOYdNQcWbVAv-oWfAYk8Y70TduO8"

config :phoenix_react_server, Phoenix.React,
  component_base: Path.expand("../apps/gsmlg_component/assets/component", __DIR__),
  cache_ttl: 0
