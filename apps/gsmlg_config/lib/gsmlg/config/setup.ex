defmodule GSMLG.Config.Setup do
  def setup(config) do
    if config[:gsmlg] != nil do
      setup_gsmlg(config[:gsmlg])
    end

    if config[:logger] != nil do
      setup_logger(config[:logger])
    end

    # Skip database setup when SKIP_SANDBOX_POOL is set (during CI migrations)
    # to avoid deep_merge preserving the Sandbox pool from test.exs
    if config[:database] != nil and not skip_database_setup?() do
      setup_database(config[:database])
    end

    if config[:web] != nil do
      setup_web(config[:web])
    end

    if config[:admin_web] != nil do
      setup_admin_web(config[:admin_web])
    end

    if config[:couchdb] != nil do
      setup_couchdb(config[:couchdb])
    end

    if config[:commander] != nil do
      setup_commander(config[:commander])
    end

    if config[:browser] != nil do
      setup_browser(config[:browser])
    end

    if config[:browser_agent] != nil do
      setup_browser_agent(config[:browser_agent])
    end

    if config[:cluster] != nil do
      setup_cluster(config[:cluster])
    end

    if config[:oauth] != nil do
      setup_oauth(config[:oauth])
    end

    if config[:web_push] != nil do
      setup_web_push(config[:web_push])
    end

    if config[:scout] != nil do
      setup_scout(config[:scout])
    end

    if config[:proxy_rules] != nil do
      setup_proxy_rules(config[:proxy_rules])
    end

    if config[:caddy] != nil do
      setup_caddy(config[:caddy])
    end

    if config[:storage] != nil do
      setup_storage(config[:storage])
    end

    if config[:i18n] != nil do
      setup_i18n(config[:i18n])
    end
  end

  def setup_gsmlg(config) do
    if config[:tailwind_path] != nil do
      tailwind_path = config[:tailwind_path]
      Application.put_env(:tailwind, :path, tailwind_path)
    else
      tailwind_path = System.find_executable("tailwindcss")
      Application.put_env(:tailwind, :path, tailwind_path)
    end

    if config[:bun_path] != nil do
      bun_path = config[:bun_path]
      Application.put_env(:bun, :path, bun_path)
    else
      bun_path = System.find_executable("bun")
      Application.put_env(:bun, :path, bun_path)
    end
  end

  def setup_logger(config) do
    log_level = config[:log_level] || "info"
    GSMLG.Logger.configure_log_level!(log_level)
  end

  def setup_database(config) do
    # DATABASE_URL from env takes priority (set by devenv or deployment)
    if url = System.get_env("DATABASE_URL") do
      port = database_url_port(url, config[:port] || 5432)

      db_config = [
        url: url,
        pool_size: config[:pool_size] || 10,
        show_sensitive_data_on_connection_error:
          config[:show_sensitive_data_on_connection_error] || get_env() == :dev
      ]

      # devenv exports PGHOST even when its Postgres service is stopped. Only
      # use the Unix socket when Postgres has created the socket file.
      db_config =
        case System.get_env("PGHOST") do
          "/" <> _ = pghost ->
            if postgres_socket_ready?(pghost, port) do
              db_config
              |> Keyword.put(:socket_dir, pghost)
              |> Keyword.put(:port, port)
            else
              db_config
            end

          _ ->
            db_config
        end

      update_env(:gsmlg, GSMLG.Repo, db_config)
    else
      base_config = [
        username: config[:username],
        password: config[:password],
        database: config[:database],
        pool_size: config[:pool_size],
        show_sensitive_data_on_connection_error:
          config[:show_sensitive_data_on_connection_error] || get_env() == :dev
      ]

      # Add connection config - prefer socket_dir over hostname
      connection_config =
        cond do
          config[:socket_dir] not in [nil, ""] ->
            [socket_dir: config[:socket_dir]]

          config[:hostname] not in [nil, ""] ->
            [hostname: config[:hostname], port: config[:port] || 5432]

          true ->
            [hostname: "localhost", port: config[:port] || 5432]
        end

      update_env(:gsmlg, GSMLG.Repo, base_config ++ connection_config)
    end
  end

  def setup_web(config) do
    uri = URI.parse(config[:url])

    check_origin = parse_check_origin(config[:check_origin])

    update_env(:gsmlg_web, GSMLG.Web.Endpoint,
      secret_key_base: config[:secret_key_base],
      check_origin: check_origin,
      http: [
        ip: {0, 0, 0, 0, 0, 0, 0, 0},
        port: config[:port]
      ],
      server: config[:server] != false,
      url: [host: uri.host, port: uri.port, scheme: uri.scheme, path: uri.path],
      user_register: config[:user_register] == true,
      enable_adsense: config[:enable_adsense] == true,
      show_icp: config[:show_icp] == true
    )
  end

  def setup_admin_web(config) do
    uri = URI.parse(config[:url])

    check_origin = parse_check_origin(config[:check_origin])

    update_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint,
      adapter: Bandit.PhoenixAdapter,
      secret_key_base: config[:secret_key_base],
      check_origin: check_origin,
      http: [
        ip: {0, 0, 0, 0, 0, 0, 0, 0},
        port: config[:port]
      ],
      server: config[:server] != false,
      url: [host: uri.host, port: uri.port, scheme: uri.scheme, path: uri.path],
      user_register: config[:user_register] == true,
      client_certificate_auth: config[:client_certificate_auth] == true
    )
  end

  def setup_couchdb(config) do
    update_env(:gsmlg_couchdb, GSMLG.CouchDB.Connection,
      host: config[:host],
      port: config[:port],
      username: config[:username],
      password: config[:password]
    )
  end

  def setup_commander(config) do
    platform_key = resolve_commander_platform_key!(config)
    platform_credentials = resolve_commander_platform_credentials!(config)

    commander_config = [
      start: config[:start] == true,
      name: config[:name],
      credential_id: config[:credential_id] || config[:name],
      platform_url: commander_platform_url(config),
      platform_key: platform_key,
      platform_credentials: platform_credentials,
      features: normalize_commander_features(config[:features]),
      auth_timestamp_window_seconds: config[:auth_timestamp_window_seconds] || 60,
      auth_nonce_ttl_ms: config[:auth_nonce_ttl_ms] || 120_000,
      max_in_flight_rpcs: config[:max_in_flight_rpcs] || 2,
      tls: normalize_commander_tls(config[:tls])
    ]

    commander_config =
      if Map.has_key?(config, :server) do
        Keyword.put(commander_config, :server, config[:server] == true)
      else
        commander_config
      end

    update_env(:gsmlg_commander, GSMLG.Commander, commander_config)
  end

  def setup_browser(config) do
    jobs = config[:jobs] || %{}
    security = config[:security] || %{}

    Application.put_env(:gsmlg_browser, :settings, config)
    Application.put_env(:gsmlg_browser, :enabled, config[:enabled] == true)
    Application.put_env(:gsmlg_browser, :default_node, config[:default_node])

    Application.put_env(
      :gsmlg_browser,
      :inline_artifact_max_bytes,
      config[:inline_artifact_max_bytes]
    )

    Application.put_env(:gsmlg_browser, :event_retention_days, config[:event_retention_days])
    Application.put_env(:gsmlg_browser, :upload_base_url, config[:upload_base_url])
    Application.put_env(:gsmlg_browser, :upload_ttl_seconds, config[:upload_ttl_seconds])
    Application.put_env(:gsmlg_browser, :dispatch_timeout_ms, jobs[:dispatch_timeout_ms])
    Application.put_env(:gsmlg_browser, :rpc_timeout_ms, jobs[:dispatch_timeout_ms])
    Application.put_env(:gsmlg_browser, :reconcile_interval_ms, jobs[:reconcile_interval_ms])
    Application.put_env(:gsmlg_browser, :default_deadline_ms, jobs[:default_deadline_ms])
    Application.put_env(:gsmlg_browser, :max_attempts, jobs[:max_attempts])
    Application.put_env(:gsmlg_browser, :allowed_schemes, security[:allowed_schemes])
    Application.put_env(:gsmlg_browser, :allow_css_locator, security[:allow_css_locator])
    Application.put_env(:gsmlg_browser, :allow_downloads, security[:allow_downloads])

    Application.put_env(
      :gsmlg_browser,
      :max_observation_bytes,
      security[:max_observation_bytes]
    )

    Application.put_env(:gsmlg_browser, :max_artifact_bytes, security[:max_artifact_bytes])
    configure_browser_queues(config[:enabled] == true)
  end

  def setup_browser_agent(config) do
    Application.put_env(:gsmlg_browser_agent, :settings, config)
  end

  defp resolve_commander_platform_key!(config) do
    value =
      case config[:platform_key] do
        key when is_binary(key) and key != "" -> key
        _missing -> runtime_secret(config[:platform_key_env])
      end

    if config[:start] == true and not (is_binary(value) and value != "") do
      raise ArgumentError, "missing runtime Commander credential"
    end

    value
  end

  defp runtime_secret(variable) when is_binary(variable) and variable != "" do
    case System.get_env(variable) do
      value when is_binary(value) and value != "" -> value
      _missing -> nil
    end
  end

  defp runtime_secret(_variable), do: nil

  defp resolve_commander_platform_credentials!(config) do
    credentials = config[:platform_credentials] || %{}

    cond do
      map_size(credentials) > 0 ->
        credentials

      config[:server] == true ->
        with variable when is_binary(variable) and variable != "" <-
               config[:platform_credentials_env],
             encoded when is_binary(encoded) and encoded != "" <- System.get_env(variable),
             {:ok, decoded} when is_map(decoded) and map_size(decoded) > 0 <-
               JSON.decode(encoded),
             true <- Enum.all?(decoded, &valid_runtime_credential?/1) do
          decoded
        else
          _invalid -> raise ArgumentError, "missing or invalid runtime Commander credential map"
        end

      true ->
        %{}
    end
  end

  defp valid_runtime_credential?({credential_id, entry})
       when is_binary(credential_id) and credential_id != "" and is_map(entry) do
    key = Map.get(entry, "key")
    name = Map.get(entry, "commander_name")
    is_binary(key) and key != "" and is_binary(name) and name != ""
  end

  defp valid_runtime_credential?(_entry), do: false

  defp configure_browser_queues(enabled?) do
    config = Application.get_env(:gsmlg, Oban, [])
    queues = Keyword.get(config, :queues, [])
    queues = Keyword.drop(queues, [:browser_dispatch, :browser_reconcile, :browser_retention])

    queues =
      if enabled? do
        Keyword.merge(queues,
          browser_dispatch: 2,
          browser_reconcile: 1,
          browser_retention: 1
        )
      else
        queues
      end

    Application.put_env(:gsmlg, Oban, Keyword.put(config, :queues, queues))
  end

  defp commander_platform_url(%{platform_url: platform_url})
       when is_binary(platform_url) and platform_url != "" do
    platform_url
  end

  defp commander_platform_url(%{umbrella_server_url: umbrella_server_url}) do
    umbrella_server_url_to_platform_url(umbrella_server_url)
  end

  defp commander_platform_url(_config), do: nil

  defp umbrella_server_url_to_platform_url(url) when is_binary(url) do
    url = String.trim(url)

    uri =
      if URI.parse(url).scheme do
        URI.parse(url)
      else
        URI.parse("http://#{url}")
      end

    scheme =
      case uri.scheme do
        "https" -> "wss"
        "http" -> "ws"
        scheme -> scheme
      end

    path =
      case uri.path do
        nil -> "/commander-socket/websocket"
        "" -> "/commander-socket/websocket"
        "/" -> "/commander-socket/websocket"
        path -> path
      end

    %URI{uri | scheme: scheme, path: path, query: nil, fragment: nil}
    |> URI.to_string()
  end

  defp umbrella_server_url_to_platform_url(_url), do: nil

  defp normalize_commander_features(nil), do: [:pty]

  defp normalize_commander_features(features) when is_list(features) do
    features
    |> Enum.map(&normalize_commander_feature/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_commander_feature(feature) when is_atom(feature), do: feature
  defp normalize_commander_feature("pty"), do: :pty
  defp normalize_commander_feature(_feature), do: nil

  defp normalize_commander_tls(nil), do: [enabled: false, reload_interval_ms: 60_000]

  defp normalize_commander_tls(tls) when is_map(tls) do
    [
      enabled: tls[:enabled] == true,
      client_cert_file: tls[:client_cert_file],
      client_key_file: tls[:client_key_file],
      ca_cert_file: tls[:ca_cert_file],
      reload_interval_ms: tls[:reload_interval_ms] || 60_000
    ]
  end

  def setup_cluster(config) do
    config = GSMLG.Config.Cluster.normalize(config)
    topologies = GSMLG.Config.Cluster.topologies(config)

    Application.put_env(:gsmlg, :cluster, config)
    Application.put_env(:libcluster, :topologies, topologies)
  end

  def setup_oauth(config) do
    if config[:github] != nil do
      Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth,
        client_id: config[:github][:client_id],
        client_secret: config[:github][:client_secret]
      )
    end
  end

  def setup_web_push(config) do
    update_env(:gsmlg_web_push, :vapid_details,
      subject: config[:subject],
      public_key: config[:public_key],
      private_key: config[:private_key]
    )
  end

  def setup_scout(config) do
    Application.put_env(:gsmlg_scout, :settings, config || %{})
  end

  def setup_proxy_rules(config) do
    Application.put_env(:proxy_rules, :settings, config || %{})
  end

  def setup_i18n(config) do
    Application.put_env(:gsmlg, :i18n, default_locale: config[:default_locale])
  end

  def setup_caddy(config) do
    Application.put_env(:caddy, :start, config[:start] == true)
    Application.put_env(:caddy, :mode, String.to_atom(config[:mode] || "external"))
    Application.put_env(:caddy, :admin_url, config[:admin_url])
    Application.put_env(:caddy, :health_interval, config[:health_interval])
  end

  def setup_storage(config) do
    if config[:s3_bucket] != nil do
      Application.put_env(:gsmlg_storage, :s3_bucket, config[:s3_bucket])
    end

    if config[:s3_endpoint] not in [nil, ""] do
      Application.put_env(:gsmlg_storage, :s3_endpoint, config[:s3_endpoint])
    end

    if config[:s3_region] not in [nil, ""] do
      Application.put_env(:gsmlg_storage, :s3_region, config[:s3_region])
    end

    if config[:max_file_size] != nil do
      Application.put_env(:gsmlg_storage, :max_file_size, config[:max_file_size])
    end

    if config[:cleanup_interval] != nil do
      Application.put_env(:gsmlg_storage, :cleanup_interval, config[:cleanup_interval])
    end

    if config[:retention_window] != nil do
      Application.put_env(:gsmlg_storage, :retention_window, config[:retention_window])
    end
  end

  def update_env(app, key, new_value) do
    current = Application.get_env(app, key, [])
    merged = deep_merge(current, new_value)
    Application.put_env(app, key, merged)
  end

  def deep_merge(old, new) when is_list(old) and is_list(new) do
    if Keyword.keyword?(old) and Keyword.keyword?(new) do
      Keyword.merge(old, new, fn _key, val1, val2 ->
        deep_merge(val1, val2)
      end)
    else
      new
    end
  end

  def deep_merge(%{} = old, %{} = new) do
    Map.merge(old, new, fn _key, val1, val2 ->
      deep_merge(val1, val2)
    end)
  end

  def deep_merge(_old, new), do: new

  # Parse check_origin config value
  # Supports: boolean, list of strings (patterns), or nil (defaults to false for proxy setups)
  defp parse_check_origin(nil), do: false
  defp parse_check_origin(value) when is_boolean(value), do: value
  defp parse_check_origin(value) when is_list(value), do: value

  defp database_url_port(url, fallback) do
    case URI.parse(url) do
      %URI{port: port} when is_integer(port) -> port
      _ -> env_database_port(fallback)
    end
  end

  defp env_database_port(fallback) do
    port = System.get_env("PGPORT") || System.get_env("POSTGRES_PORT") || to_string(fallback)

    case Integer.parse(port) do
      {parsed, ""} -> parsed
      _ -> fallback
    end
  end

  defp postgres_socket_ready?(socket_dir, port) do
    File.exists?(Path.join(socket_dir, ".s.PGSQL.#{port}"))
  end

  # Get the current environment, works both in Mix and release
  defp get_env do
    cond do
      env_str = System.get_env("MIX_ENV") ->
        String.to_atom(env_str)

      function_exported?(Mix, :env, 0) ->
        Mix.env()

      true ->
        :prod
    end
  end

  # Check if database setup should be skipped (for CI migrations)
  defp skip_database_setup? do
    System.get_env("SKIP_SANDBOX_POOL") != nil
  end
end
