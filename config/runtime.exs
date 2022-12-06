import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.
if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  config :gsmlg, GSMLG.Repo,
    # ssl: true,
    # socket_options: [:inet6],
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  config :gsmlg_web, GSMLGWeb.Endpoint,
    home_page_title: System.get_env("HOME_PAGE_TITLE", "Home"),
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: String.to_integer(System.get_env("PORT", "4110"))
    ],
    secret_key_base: secret_key_base

  # ## Using releases
  #
  # If you are doing OTP releases, you need to instruct Phoenix
  # to start each relevant endpoint:
  #
  config :gsmlg_web, GSMLGWeb.Endpoint, server: true

  if System.get_env("HOST") do
    host = System.get_env("HOST")
    port = String.to_integer(System.get_env("HOST_PORT", "80"))
    config :gsmlg_web, GSMLGWeb.Endpoint, url: [host: host, port: port]
  end

  config :gsmlg_web, GSMLGWeb.Endpoint,
    user_register: System.get_env("USER_REGISTER") == "on",
    enable_adsense: System.get_env("ENABLE_ADSENSE", "no"),
    show_icp: System.get_env("SHOW_ICP", "no")

  admin_secret_key_base =
    System.get_env("ADMIN_SECRET_KEY_BASE") || System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable ADMIN_SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  config :gsmlg_admin_web, GSMLGAdminWeb.Endpoint,
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: String.to_integer(System.get_env("ADMIN_PORT", "4111"))
    ],
    secret_key_base: admin_secret_key_base

  config :gsmlg_admin_web, GSMLGAdminWeb.Endpoint, server: true

  if System.get_env("ADMIN_HOST") do
    host = System.get_env("ADMIN_HOST")
    port = System.get_env("ADMIN_HOST_PORT", "80") |> String.to_integer()
    config :gsmlg_admin_web, GSMLGAdminWeb.Endpoint, url: [host: host, port: port]
  end

  config :gsmlg_admin_web, GSMLGAdminWeb.Endpoint,
    user_register: System.get_env("USER_REGISTER") == "on"

  # Then you can assemble a release by calling `mix release`.
  # See `mix help release` for more information.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Also, you may need to configure the Swoosh API client of your choice if you
  # are not using SMTP. Here is an example of the configuration:
  #
  #     config :gsmlg, GSMLG.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # For this example you need include a HTTP client required by Swoosh API client.
  # Swoosh supports Hackney and Finch out of the box:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Hackney
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.

  # CouchDB Server Connection
  if System.get_env("COUCH_HOST") do
    config :gsmlg_couchdb, GSMLG_CouchDB.Connection,
      host: System.get_env("COUCH_HOST"),
      port: System.get_env("COUCH_PORT") |> String.to_integer(),
      username: System.get_env("COUCH_USER"),
      password: System.get_env("COUCH_PASS")
  end
end
