# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

# Configure Mix tasks and generators
config :gsmlg,
  namespace: GSMLG,
  ecto_repos: [GSMLG.Repo]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :gsmlg, GSMLG.Mailer, adapter: Swoosh.Adapters.Local

# Setup guardian
config :gsmlg_web, GSMLGWeb.Guardian,
  issuer: "gsmlg",
  secret_key: "s5XC5yzTm66tg+1pbiQiJxWNUAvPK4UeAOUJVO1VYkrT2cyr/1usjyYHr8K2ymLc"

config :gsmlg_admin_web, GSMLGAdminWeb.Guardian,
  issuer: "gsmlg",
  secret_key: "s5XC5yzTm66tg+1pbiQiJxWNUAvPK4UeAOUJVO1VYkrT2cyr/1usjyYHr8K2ymLc"

config :guardian, Guardian,
  issuer: "gsmlg",
  secret_key: Mix.env(),
  serializer: GSMLG.Guardian.Serializer

config :guardian, Guardian.DB,
  # Add your repository module
  repo: GSMLG.Repo,
  # default
  schema_name: "user_tokens",
  # store all token types if not set
  # token_types: ["refresh_token"],
  # default: 60 minutes
  sweep_interval: 60

# Swoosh API client is needed for adapters other than SMTP.
config :swoosh, :api_client, false

config :gsmlg_web,
  namespace: GSMLGWeb,
  ecto_repos: [GSMLG.Repo],
  generators: [context_app: :gsmlg]

# Configures the endpoint
config :gsmlg_web, GSMLGWeb.Endpoint,
  url: [host: "localhost"],
  secret_key_base: "oHywixWzSdklwLkMiE+SUaNdMDu5gTcmEggpHA9LhRTdb8DgLWBDQNXrOu0wCLEr",
  render_errors: [
    formats: [html: GSMLGWeb.ErrorHTML, json: GSMLGWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: GSMLG.PubSub,
  home_page_title: "Home",
  live_view: [signing_salt: "gmmaSSOy"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.14.29",
  default: [
    args: ~w(js/app.js --bundle --target=es2021 --format=iife --outdir=../priv/static/assets),
    cd: Path.expand("../apps/gsmlg_web/assets", __DIR__)
  ],
  admin: [
    args: ~w(js/app.js --bundle --target=es2021 --format=iife --outdir=../priv/static/assets),
    cd: Path.expand("../apps/gsmlg_admin_web/assets", __DIR__)
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.1.8",
  default: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../apps/gsmlg_web/assets", __DIR__)
  ],
  admin: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../apps/gsmlg_admin_web/assets", __DIR__)
  ]

admin_secret_key_base = "oHywixWzSdklwLkMiE+SUaNdMDu5gTcmEggpHA9LhRTdb8DgLWBDQNXrOu0wCLEr"

# Configures the endpoint
config :gsmlg_admin_web, GSMLGAdminWeb.Endpoint,
  url: [host: "localhost"],
  secret_key_base: admin_secret_key_base,
  commander_platform_key: admin_secret_key_base,
  render_errors: [
    formats: [html: GSMLGWeb.ErrorHTML, json: GSMLGWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: GSMLG.PubSub,
  live_view: [signing_salt: "gmmaSSOy"]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Notice `config :mnesia, dir:` value type is `chart_list`
mnesia_dir =
  String.to_charlist(Path.expand("../_build/tmp/mnesia/#{Mix.env()}/#{node()}", __DIR__))

config :mnesia, dir: mnesia_dir

config :amqp,
  connections: [],
  channels: []

config :gsmlg_couchdb, GSMLG.CouchDB.Connection, scheme: :http

config :gsmlg_tor, GSMLG.Tor.Config,
  auto_download: true,
  bin_path: nil,
  conf_path: nil,
  conf: nil

config :gsmlg_commander, GSMLGCommander,
  name: "gsmlg_commander",
  platform_url: "ws://localhost:4111/socket/websocket",
  secret_key_base: admin_secret_key_base

# Configures the endpoint
config :livebook, LivebookWeb.Endpoint,
  url: [host: "localhost", path: "/"],
  pubsub_server: Livebook.PubSub,
  live_view: [signing_salt: "livebook"],
  drainer: [shutdown: 1000],
  render_errors: [formats: [html: LivebookWeb.ErrorHTML], layout: false]

# Add mime type to upload notebooks with `Phoenix.LiveView.Upload`
config :mime, :types, %{
  "text/plain" => ["livemd"]
}

# We want CSRF tokens to be logged to help users with debugging
config :plug_cowboy, :log_exceptions_with_status_code, [407..599]

config :livebook,
  app_service_name: nil,
  app_service_url: nil,
  authentication_mode: :token,
  feature_flags: [],
  force_ssl_host: nil,
  learn_notebooks: [],
  plugs: [],
  shutdown_callback: nil,
  update_instructions_url: nil,
  within_iframe: false,
  allowed_uri_schemes: []

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
