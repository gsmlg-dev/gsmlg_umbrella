import Config

# Database configuration for tests
# Uses localhost by default for CI compatibility
# Set SKIP_SANDBOX_POOL=true for migrations to avoid Sandbox pool lock issues

pool_config =
  cond do
    # Skip Sandbox pool for migrations (set explicitly in CI)
    System.get_env("SKIP_SANDBOX_POOL") != nil ->
      [pool: DBConnection.ConnectionPool]

    # When POSTGRES_HOST is set (CI), use standard pool - runtime.exs handles this
    # but we still need to NOT set Sandbox here to avoid conflicts
    System.get_env("POSTGRES_HOST") != nil ->
      []

    # Local development: Sandbox pool for running tests
    true ->
      [pool: Ecto.Adapters.SQL.Sandbox]
  end

# Base database config - supports Unix socket via PGHOST
db_base_config =
  [
    username: System.get_env("POSTGRES_USER", "gsmlg_test"),
    password: System.get_env("POSTGRES_PASSWORD", "gsmlg_test"),
    database: System.get_env("POSTGRES_DB", "gsmlg_test") <> "#{System.get_env("MIX_TEST_PARTITION")}",
    pool_size: 10
  ]
  |> then(fn config ->
    case System.get_env("PGHOST") do
      nil ->
        config ++
          [
            hostname: System.get_env("POSTGRES_HOST", "localhost"),
            port: String.to_integer(System.get_env("POSTGRES_PORT", "5432"))
          ]

      pghost ->
        if String.starts_with?(pghost, "/") do
          # Unix socket path
          config ++ [socket_dir: pghost]
        else
          config ++
            [
              hostname: pghost,
              port: String.to_integer(System.get_env("POSTGRES_PORT", "5432"))
            ]
        end
    end
  end)

config :gsmlg, GSMLG.Repo, Keyword.merge(db_base_config, pool_config)

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
