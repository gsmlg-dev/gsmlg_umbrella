import Config

# Custom plural forms to support BCP 47 script-subtag locales (e.g. zh-Hans, zh-Hant)
config :gettext, plural_forms: GSMLG.Component.Gettext.Plural

config :gsmlg,
  namespace: GSMLG,
  ecto_repos: [GSMLG.Repo]

config :gsmlg, GSMLG.Mailer, adapter: Swoosh.Adapters.Local

# Encryption key for TranslationProviderSetting.api_key (AES-256-GCM via EncryptedString type).
# Override with GSMLG_TRANSLATION_KEY env var in production.
config :gsmlg,
       :translation_encryption_key,
       System.get_env("GSMLG_TRANSLATION_KEY", "dev_only_key_do_not_use_in_prod_!")

config :gsmlg, Styx,
  repo: GSMLG.Repo,
  queues: [translations: 5, storage_cleanup: 2, gao_note_index: 2],
  plugins: [
    {Styx.Pruner, max_age: 60 * 60 * 24 * 7}
  ]

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
  adapter: Gaoxy.PhoenixAdapter,
  render_errors: [
    formats: [html: GSMLG.Web.ErrorHTML, json: GSMLG.Web.ErrorJSON],
    layout: false
  ],
  pubsub_server: GSMLG.PubSub,
  live_view: [signing_salt: "gmmaSSOy"]

# Configures the endpoint
config :gsmlg_admin_web, GSMLG.AdminWeb.Endpoint,
  adapter: Gaoxy.PhoenixAdapter,
  render_errors: [
    formats: [html: GSMLG.AdminWeb.ErrorHTML, json: GSMLG.AdminWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: GSMLG.PubSub,
  live_view: [signing_salt: "gmmaSSOy"]

# Vize's GNU prebuilts require glibc 2.43; build for our Nix and Debian environments.
config :rustler_precompiled, :force_build, duskmoon_vize: true

for app <- [:gsmlg_web, :gsmlg_admin_web] do
  app_dir = Path.expand("../apps/#{app}", __DIR__)
  component_dir = Path.expand("../apps/gsmlg_component", __DIR__)
  duskmoon_dir = Path.expand("../deps/phoenix_duskmoon/lib", __DIR__)

  config :duskmoon_bundler, app,
    root: Path.join(app_dir, "assets"),
    entry: Path.join(app_dir, "assets/js/app.js"),
    outdir: Path.join(app_dir, "priv/static/assets"),
    target: :es2020,
    format: :esm,
    sourcemap: :hidden,
    resolve_dirs: [Path.expand("../apps", __DIR__), Path.expand("../deps", __DIR__)],
    external: ~w(/fonts/* /images/* https://*),
    tailwind: [
      css: Path.join(app_dir, "assets/css/app.css"),
      sources: [
        %{base: Path.join(app_dir, "lib"), pattern: "**/*.{ex,exs,heex,holo}"},
        %{base: Path.join(app_dir, "assets"), pattern: "**/*.{css,js,mjs,ts,jsx,tsx}"},
        %{base: Path.join(component_dir, "lib"), pattern: "**/*.{ex,exs,heex}"},
        %{base: Path.join(component_dir, "assets"), pattern: "**/*.{css,js,ts,jsx,tsx}"},
        %{base: duskmoon_dir, pattern: "**/*.{ex,heex}"}
      ]
    ],
    server: [watch_dirs: [Path.join(app_dir, "lib"), component_dir, duskmoon_dir]]

  # Resolve manifests relative to the installed OTP app in a release.
  config :duskmoon_bundler_runtime, app, outdir: "priv/static/assets"
end

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :phoenix,
       :filter_parameters,
       ~w(password password_confirmation token certificate signature nonce sign_at platform_key)

config :concord,
  cluster_enabled: false,
  clustering: false

config :gsmlg_couchdb, GSMLG.CouchDB.Connection, scheme: :http

config :gsmlg_tor, GSMLG.Tor.Config,
  auto_download: true,
  bin_path: nil,
  conf_path: nil,
  conf: nil

config :tesla,
  adapter: GSMLG.AWS.HTTPFetchAdapter

# Add mime type to upload notebooks with `Phoenix.LiveView.Upload`
config :mime, :types, %{
  "text/plain" => ["livemd"]
}

# Commander System Configuration
# The Commander system supports two modes:
# - Agent mode (start: true): Runs on remote machines, connects to control server
# - Server mode (start_server: true): Control server that manages agents
config :gsmlg_commander,
  # Server configuration
  server: [
    # Agent WebSocket endpoint
    agent_endpoint: "/agent/connect",
    # Operator WebSocket endpoint
    operator_endpoint: "/operator/terminal",

    # Connection settings
    heartbeat_interval_ms: 30_000,
    heartbeat_timeout_ms: 90_000,
    reconnect_grace_period_ms: 120_000,

    # Limits
    max_agents: 10_000,
    max_ptys_per_agent: 10,
    max_observers_per_pty: 5,
    max_output_buffer_bytes: 1_048_576
  ],

  # Authentication configuration
  auth: [
    # Agent auth: :token | :certificate | :oauth
    agent_auth_type: :token,
    agent_token_secret: {:system, "COMMANDER_AGENT_SECRET"},

    # Operator auth: :jwt
    operator_auth_type: :jwt,
    jwt_secret: {:system, "COMMANDER_JWT_SECRET"}
  ],

  # Policy engine configuration
  policy: [
    # Default policy for users without explicit rules
    # :none | :tagged | :all
    default_access: :none,

    # Enable tag-based access (user metadata -> agent tags)
    enable_tag_matching: true,

    # Default max PTYs per user
    default_max_ptys: 5,

    # Admin users (bypass all policy checks)
    admin_users: []
  ],

  # Telemetry configuration
  telemetry: [
    enabled: true,
    forward_to_gsmlg_telemetry: true
  ],

  # Audit logging
  audit: [
    enabled: true,
    log_command_content: false,
    backend: :logger,
    max_entries: 10_000
  ]

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
    # Commander system metrics
    [:commander, :session, :started],
    [:commander, :session, :terminated],
    [:commander, :session, :authenticated],
    [:commander, :session, :disconnected],
    [:commander, :session, :reconnected],
    [:commander, :pty, :spawned],
    [:commander, :policy, :authorization],
    [:commander, :audit, :session_created],
    [:commander, :manager, :health_check]
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

# Caddy does not start by default; configure via TOML [caddy] section
config :caddy, start: false

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
