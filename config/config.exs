import Config

config :gsmlg,
  namespace: GSMLG,
  ecto_repos: [GSMLG.Repo]

config :gsmlg, GSMLG.Mailer, adapter: Swoosh.Adapters.Local

# Setup guardian
config :gsmlg_web, GSMLG.Web.Guardian,
  issuer: "gsmlg",
  secret_key: "s5XC5yzTm66tg+1pbiQiJxWNUAvPK4UeAOUJVO1VYkrT2cyr/1usjyYHr8K2ymLc"

config :gsmlg_admin_web, GSMLG.AdminWeb.Guardian,
  issuer: "gsmlg",
  secret_key: "s5XC5yzTm66tg+1pbiQiJxWNUAvPK4UeAOUJVO1VYkrT2cyr/1usjyYHr8K2ymLc"

config :guardian, Guardian,
  issuer: "gsmlg",
  secret_key: Mix.env(),
  serializer: GSMLG.Guardian.Serializer

config :guardian, Guardian.DB,
  repo: GSMLG.Repo,
  schema_name: "user_tokens",
  # store all token types if not set
  # token_types: ["refresh_token"],
  # default: 60 minutes
  sweep_interval: 60

config :ueberauth, Ueberauth,
  providers: [
    github: {Ueberauth.Strategy.Github, []}
  ]

# Swoosh API client is needed for adapters other than SMTP.
config :swoosh, :api_client, false

config :gsmlg_web,
  namespace: GSMLG.Web,
  ecto_repos: [GSMLG.Repo],
  generators: [context_app: :gsmlg]

# Phoenix 1.8 Scopes configuration for security-by-default
config :gsmlg_web, :phoenix_generators,
  scope: [
    default: true,
    module: GSMLG.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_table: :users,
    schema_type: :string,
    route_prefix: nil,
    test_data_fixture: GSMLG.Accounts.Fixtures
  ]

# Configures the endpoint
config :gsmlg_web, GSMLG.Web.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: GSMLG.Web.ErrorHTML, json: GSMLG.Web.ErrorJSON],
    layout: false
  ],
  pubsub_server: GSMLG.PubSub,
  live_view: [signing_salt: "gmmaSSOy"]

# Configures the endpoint
config :gsmlg_admin_web, GSMLG.AdminWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: GSMLG.AdminWeb.ErrorHTML, json: GSMLG.AdminWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: GSMLG.PubSub,
  live_view: [signing_salt: "gmmaSSOy"]

config :bun,
  version: "1.2.15",
  gsmlg_web: [
    args:
      ~w(build assets/js/app.js assets/js/sw.js assets/js/worker.js --outdir=priv/static/assets --external /fonts/* --external /images/*),
    cd: Path.expand("../apps/gsmlg_web", __DIR__),
    env: %{}
  ],
  gsmlg_admin_web: [
    args:
      ~w(build assets/js/app.js assets/js/sw.js --outdir=priv/static/assets --external /fonts/* --external /images/*),
    cd: Path.expand("../apps/gsmlg_admin_web", __DIR__),
    env: %{}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.11",
  gsmlg_web: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/app.css
    ),
    cd: Path.expand("../apps/gsmlg_web", __DIR__)
  ],
  gsmlg_admin_web: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/app.css
    ),
    cd: Path.expand("../apps/gsmlg_admin_web", __DIR__)
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Notice `config :mnesia, dir:` value type is `chart_list`
mnesia_dir =
  Path.expand("../_build/tmp/mnesia/#{Mix.env()}/#{node()}", __DIR__)

config :mnesia, dir: to_charlist(mnesia_dir)

config :gsmlg_couchdb, GSMLG.CouchDB.Connection, scheme: :http

config :gsmlg_tor, GSMLG.Tor.Config,
  auto_download: true,
  bin_path: nil,
  conf_path: nil,
  conf: nil

config :tesla,
  adapter: {Tesla.Adapter.Finch, name: GSMLG.Finch}

# Add mime type to upload notebooks with `Phoenix.LiveView.Upload`
config :mime, :types, %{
  "text/plain" => ["livemd"]
}

# Commander E2E Test configuration
config :gsmlg_commander_test,
  # Server settings
  server_port: 14000,
  # Timeouts
  connect_timeout: 5_000,
  scenario_timeout: 30_000,
  health_check_timeout: 10_000,
  # Test configuration for server
  server_config: [
    idle_timeout: :timer.seconds(30),
    reconnect_grace_period: :timer.seconds(10),
    heartbeat_interval: :timer.seconds(5)
  ],
  # Reporters
  reporters: [:console]

# GSMLG Telemetry configuration
config :gsmlg_telemetry,
  # Minimum log level
  level: :info,

  # Metrics to collect
  metrics: [
    # VM metrics
    [:vm, :memory],
    [:vm, :total_run_queue_lengths],
    # Phoenix metrics
    [:phoenix, :endpoint, :stop],
    [:phoenix, :router_dispatch, :stop],
    # Database metrics
    [:ecto, :repo, :query],
    # Custom app metrics
    [:gsmlg, :web, :request, :duration],
    [:gsmlg, :repo, :query, :duration],
    [:gsmlg, :commander, :command_execution],
    [:gsmlg, :admin, :mnesia, :fetch_info]
  ],

  # Backends configuration
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
      path: "logs/gsmlg.log",
      format: :json,
      max_file_size: 50 * 1024 * 1024,
      max_files: 5,
      compress: true,
      buffer_size: 100,
      flush_interval: 5_000
    ],
    cloudwatch: [
      enabled: false,
      log_group_name: "/gsmlg/development",
      log_stream_name: "gsmlg-#{node()}",
      region: "us-east-1",
      buffer_size: 100,
      flush_interval: 5_000
    ]
  ],

  # Metrics reporting
  report_interval: 60_000,
  max_buffer_size: 1000

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
