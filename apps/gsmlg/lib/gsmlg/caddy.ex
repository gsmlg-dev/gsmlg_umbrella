defmodule GSMLG.Caddy do
  @moduledoc """
  Caddy reverse proxy integration for GSMLG.

  Wraps the `Caddy.Supervisor` and provides helpers to configure reverse proxy
  sites for GSMLG applications. The Caddy package manages its own processes
  (ConfigProvider, ConfigManager, Logger, Server); this module is a plain
  wrapper — no extra processes needed.

  ## Supervision

  Add `GSMLG.Caddy` to your supervision tree:

      children = [
        ...,
        GSMLG.Caddy
      ]

  This delegates to `Caddy.Supervisor` under the hood, so all Caddy processes
  are started and supervised through the standard OTP mechanism.

  ## Proxy setup

  Call `setup_admin_proxy/0` after the admin web endpoint is running to register
  the Caddy reverse proxy site for `gsmlg_admin_web`.
  """

  require Logger

  @doc """
  Child spec for the Caddy supervisor.

  Delegates to `Caddy.Supervisor.child_spec/1` so that `GSMLG.Caddy` can be
  placed in any supervision tree without starting a separate process of its own.
  """
  def child_spec(opts) do
    Caddy.Supervisor.child_spec(opts)
  end

  @doc """
  Configures Caddy to reverse proxy the admin web application.

  Reads the admin web endpoint configuration (host + port) from the Application
  environment — already populated by `GSMLG.Config.Setup.setup_admin_web/1` —
  and registers a Caddy site that forwards requests to the local Phoenix endpoint.

  No-ops when:
  - `host` is `localhost` or `127.0.0.1` (no meaningful proxy in local dev)
  - Caddy processes are not running

  Returns `:ok` on success or `{:error, reason}` if the sync to Caddy fails.
  """
  def setup_admin_proxy do
    endpoint_config = Application.get_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, [])
    url_config = Keyword.get(endpoint_config, :url, [])
    http_config = Keyword.get(endpoint_config, :http, [])

    host = Keyword.get(url_config, :host)
    port = Keyword.get(http_config, :port, 4111)

    if is_binary(host) && host not in ["localhost", "127.0.0.1"] do
      :ok = Caddy.add_site(host, "reverse_proxy localhost:#{port}")

      case Caddy.sync_to_caddy() do
        :ok ->
          Logger.info("Caddy admin proxy configured: #{host} → localhost:#{port}")
          :ok

        {:error, reason} = error ->
          Logger.warning("Caddy admin proxy sync failed: #{inspect(reason)}")
          error
      end
    else
      :ok
    end
  end
end
