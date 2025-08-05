defmodule GSMLG.Config.Setup do
  def setup(config) do
    if config[:gsmlg] != nil do
      setup_gsmlg(config[:gsmlg])
    end

    if config[:database] != nil do
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

    if config[:oauth] != nil do
      setup_oauth(config[:oauth])
    end

    if config[:web_push] != nil do
      setup_web_push(config[:web_push])
    end
  end

  def setup_gsmlg(config) do
    log_level = config[:log_level] || "info"
    GSMLG.Logger.configure_log_level!(log_level)

    if config[:mnesia_dir] != nil do
      mnesia_dir = config[:mnesia_dir] |> String.to_charlist()
      update_env(:mnesia, :dir, mnesia_dir)
    end
  end

  def setup_database(config) do
    update_env(:gsmlg, GSMLG.Repo,
      username: config[:username],
      password: config[:password],
      hostname: config[:hostname],
      database: config[:database],
      pool_size: config[:pool_size],
      show_sensitive_data_on_connection_error:
        config[:show_sensitive_data_on_connection_error] || Mix.env() == :dev
    )
  end

  def setup_web(config) do
    uri = URI.parse(config[:url])

    update_env(:gsmlg_web, GSMLG.Web.Endpoint,
      secret_key_base: config[:secret_key_base],
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

    update_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint,
      adapter: Bandit.PhoenixAdapter,
      secret_key_base: config[:secret_key_base],
      http: [
        ip: {0, 0, 0, 0, 0, 0, 0, 0},
        port: config[:port]
      ],
      server: config[:server] != false,
      url: [host: uri.host, port: uri.port, scheme: uri.scheme, path: uri.path],
      user_register: config[:user_register] == true,
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
    update_env(:gsmlg_commander, GSMLG.Commander,
      name: config[:name],
      platform_url: config[:platform_url],
      platform_key: config[:platform_key]
    )
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


  def update_env(app, key, new_value) do
    current = Application.get_env(app, key, [])
    merged = deep_merge(current, new_value)
    Application.put_env(app, key, merged)
  end

  defp deep_merge(old, new) when is_list(old) and is_list(new) do
    Keyword.merge(old, new, fn _key, val1, val2 ->
      deep_merge(val1, val2)
    end)
  end

  defp deep_merge(%{} = old, %{} = new) do
    Map.merge(old, new, fn _key, val1, val2 ->
      deep_merge(val1, val2)
    end)
  end

  defp deep_merge(_old, new), do: new

end
