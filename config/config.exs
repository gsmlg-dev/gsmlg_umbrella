import Config

config :gsmlg,
  namespace: GSMLG,
  ecto_repos: [GSMLG.Repo]

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
  namespace: GSMLGWeb,
  ecto_repos: [GSMLG.Repo],
  generators: [context_app: :gsmlg]

# Configures the endpoint
config :gsmlg_web, GSMLGWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "gsmlg.org", port: 443, scheme: "https"],
  secret_key_base: "oHywixWzSdklwLkMiE+SUaNdMDu5gTcmEggpHA9LhRTdb8DgLWBDQNXrOu0wCLEr",
  render_errors: [
    formats: [html: GSMLGWeb.ErrorHTML, json: GSMLGWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: GSMLG.PubSub,
  live_view: [signing_salt: "gmmaSSOy"]

admin_secret_key_base = "oHywixWzSdklwLkMiE+SUaNdMDu5gTcmEggpHA9LhRTdb8DgLWBDQNXrOu0wCLEr"

# Configures the endpoint
config :gsmlg_admin_web, GSMLGAdminWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "admin.gsmlg.org", port: 443, scheme: "https"],
  secret_key_base: admin_secret_key_base,
  commander_platform_key: admin_secret_key_base,
  render_errors: [
    formats: [html: GSMLGAdminWeb.ErrorHTML, json: GSMLGAdminWeb.ErrorJSON],
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

config :phoenix_session_process,
  session_process: GSMLG.SessionProcess,
  max_sessions: 1_000_000,
  session_ttl: 1_440_000,
  rate_limit: 10_000

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Notice `config :mnesia, dir:` value type is `chart_list`
mnesia_dir =
  String.to_charlist(Path.expand("../_build/tmp/mnesia/#{Mix.env()}/#{node()}", __DIR__))

config :mnesia, dir: mnesia_dir

config :gsmlg_couchdb, GSMLG.CouchDB.Connection, scheme: :http

config :gsmlg_tor, GSMLG.Tor.Config,
  auto_download: true,
  bin_path: nil,
  conf_path: nil,
  conf: nil

config :gsmlg_commander, GSMLG.Commander,
  name: "gsmlg_commander",
  platform_url: "ws://localhost:4111/socket/websocket",
  secret_key_base: admin_secret_key_base

config :tesla,
  adapter: {Tesla.Adapter.Finch, name: GSMLG.Finch}

# Add mime type to upload notebooks with `Phoenix.LiveView.Upload`
config :mime, :types, %{
  "text/plain" => ["livemd"]
}

config :gsmlg_web_push, :vapid_details,
  subject: "mailto:administrator@gsmlg.com",
  public_key:
    "BIiu8m_dqtrKSvdquIqUJxsrkwswa0Zgep4myzmHlUcHjEtRdxdK4bZAEAd4dhFTARNGrbIkOJIcjdn13Z-yC4w",
  private_key: "7mYUWrgUKIE_YGuFaIw2bRO0WjreR0iY6WoE7mDwbak"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
