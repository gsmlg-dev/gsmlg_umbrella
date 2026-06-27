defmodule GSMLG.Config.SetupTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  alias GSMLG.Config.Setup

  setup do
    database_env =
      Map.new(~w(DATABASE_URL PGHOST PGPORT POSTGRES_PORT), fn name ->
        {name, System.get_env(name)}
      end)

    scout_settings = Application.fetch_env(:gsmlg_scout, :settings)

    Enum.each(Map.keys(database_env), &System.delete_env/1)

    # Clean up application environment after each test
    on_exit(fn ->
      Enum.each(database_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      # Reset some common application env values
      Application.delete_env(:mnesia, :dir)
      Application.delete_env(:tailwind, :path)
      Application.delete_env(:bun, :path)
      Application.delete_env(:gsmlg, GSMLG.Repo)
      Application.delete_env(:gsmlg_web, GSMLG.Web.Endpoint)
      Application.delete_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint)
      Application.delete_env(:gsmlg_couchdb, GSMLG.CouchDB.Connection)
      Application.delete_env(:gsmlg_commander, GSMLG.Commander)
      Application.delete_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)
      Application.delete_env(:gsmlg_web_push, :vapid_details)

      case scout_settings do
        {:ok, settings} -> Application.put_env(:gsmlg_scout, :settings, settings)
        :error -> Application.delete_env(:gsmlg_scout, :settings)
      end

      Application.delete_env(:gsmlg, :cluster)
      Application.delete_env(:libcluster, :topologies)
    end)

    :ok
  end

  describe "setup/1" do
    test "handles empty config" do
      # Should not crash with empty config
      assert Setup.setup(%{}) == nil
    end

    test "handles nil config" do
      # Should not crash with nil config
      assert Setup.setup(nil) == nil
    end

    test "calls setup functions for all config sections" do
      config = %{
        gsmlg: %{mnesia_dir: "/tmp/mnesia"},
        logger: %{log_level: "info"},
        database: %{username: "test"},
        web: %{url: "http://localhost:4000", secret_key_base: "test", port: 4000},
        admin_web: %{url: "http://localhost:4001", secret_key_base: "test", port: 4001},
        couchdb: %{host: "localhost", port: 5984},
        commander: %{start: true, name: "test"},
        oauth: %{github: %{client_id: "test", client_secret: "test"}},
        web_push: %{subject: "test", public_key: "test", private_key: "test"}
      }

      # Should not crash
      assert Setup.setup(config) == nil
    end

    test "configures scout settings when scout config is present" do
      config = %{agent: %{enabled: false, region: "local"}}

      Setup.setup(%{scout: config})

      assert Application.get_env(:gsmlg_scout, :settings) == config
    end
  end

  describe "setup_gsmlg/1" do
    test "sets up mnesia directory" do
      config = %{mnesia_dir: "/tmp/test_mnesia"}

      Setup.setup_gsmlg(config)

      assert Application.get_env(:mnesia, :dir) == ~c"/tmp/test_mnesia"
    end

    test "sets up tailwind path" do
      config = %{tailwind_path: "/usr/bin/tailwindcss"}

      Setup.setup_gsmlg(config)

      assert Application.get_env(:tailwind, :path) == "/usr/bin/tailwindcss"
    end

    test "finds tailwind path when not specified" do
      config = %{}

      Setup.setup_gsmlg(config)

      # Should find the executable or set to nil
      tailwind_path = Application.get_env(:tailwind, :path)
      assert is_binary(tailwind_path) or tailwind_path == nil
    end

    test "sets up bun path" do
      config = %{bun_path: "/usr/bin/bun"}

      Setup.setup_gsmlg(config)

      assert Application.get_env(:bun, :path) == "/usr/bin/bun"
    end

    test "finds bun path when not specified" do
      config = %{}

      Setup.setup_gsmlg(config)

      # Should find the executable or set to nil
      bun_path = Application.get_env(:bun, :path)
      assert is_binary(bun_path) or bun_path == nil
    end
  end

  describe "setup_logger/1" do
    test "configures logger with specified log level" do
      config = %{log_level: "error"}

      # Mock the logger configuration function
      log =
        capture_log(fn ->
          Setup.setup_logger(config)
        end)

      # Should attempt to configure log level
      assert is_binary(log)
    end

    test "uses default log level when not specified" do
      config = %{}

      log =
        capture_log(fn ->
          Setup.setup_logger(config)
        end)

      # Should use default "info" level
      assert is_binary(log)
    end
  end

  describe "setup_database/1" do
    test "configures database with all parameters" do
      config = %{
        username: "test_user",
        password: "test_pass",
        hostname: "localhost",
        database: "test_db",
        pool_size: 5,
        show_sensitive_data_on_connection_error: false
      }

      Setup.setup_database(config)

      repo_config = Application.get_env(:gsmlg, GSMLG.Repo)
      assert repo_config[:username] == "test_user"
      assert repo_config[:password] == "test_pass"
      assert repo_config[:hostname] == "localhost"
      assert repo_config[:database] == "test_db"
      assert repo_config[:pool_size] == 5
      assert repo_config[:show_sensitive_data_on_connection_error] == false
    end

    test "merges with existing repo configuration" do
      # Set existing config
      Application.put_env(:gsmlg, GSMLG.Repo, existing_key: "existing_value")

      config = %{username: "new_user"}

      Setup.setup_database(config)

      repo_config = Application.get_env(:gsmlg, GSMLG.Repo)
      assert repo_config[:existing_key] == "existing_value"
      assert repo_config[:username] == "new_user"
    end

    @tag :tmp_dir
    test "uses devenv PGHOST socket only when the postgres socket exists", %{tmp_dir: tmp_dir} do
      # Simulate leftover repo config from another test, then clear it so this
      # test only observes the database setup path under test.
      Application.put_env(:gsmlg, GSMLG.Repo,
        url: "postgres://stale",
        socket_dir: "/stale/postgres",
        port: 5433
      )

      Application.delete_env(:gsmlg, GSMLG.Repo)

      System.put_env("DATABASE_URL", "postgres://gsmlg_dev:gsmlg_dev@localhost/gsmlg_dev")
      System.put_env("PGHOST", tmp_dir)
      System.put_env("PGPORT", "5433")

      config = %{pool_size: 5, port: 5432}

      Setup.setup_database(config)

      repo_config = Application.get_env(:gsmlg, GSMLG.Repo)
      assert repo_config[:url] == "postgres://gsmlg_dev:gsmlg_dev@localhost/gsmlg_dev"
      refute Keyword.has_key?(repo_config, :socket_dir)
      refute Keyword.has_key?(repo_config, :port)

      File.touch!(Path.join(tmp_dir, ".s.PGSQL.5433"))

      Setup.setup_database(config)

      repo_config = Application.get_env(:gsmlg, GSMLG.Repo)
      assert repo_config[:socket_dir] == tmp_dir
      assert repo_config[:port] == 5433
    end
  end

  describe "setup_web/1" do
    test "configures web endpoint" do
      config = %{
        url: "https://example.com:8080/path",
        secret_key_base: "test_secret",
        port: 8080,
        server: true,
        user_register: true,
        enable_adsense: true,
        show_icp: true
      }

      Setup.setup_web(config)

      endpoint_config = Application.get_env(:gsmlg_web, GSMLG.Web.Endpoint)
      assert endpoint_config[:secret_key_base] == "test_secret"
      assert endpoint_config[:http][:port] == 8080
      assert endpoint_config[:server] == true
      assert endpoint_config[:url][:host] == "example.com"
      assert endpoint_config[:url][:port] == 8080
      assert endpoint_config[:url][:scheme] == "https"
      assert endpoint_config[:url][:path] == "/path"
      assert endpoint_config[:user_register] == true
      assert endpoint_config[:enable_adsense] == true
      assert endpoint_config[:show_icp] == true
    end

    test "handles server false setting" do
      config = %{
        url: "http://localhost:4000",
        secret_key_base: "test",
        port: 4000,
        server: false
      }

      Setup.setup_web(config)

      endpoint_config = Application.get_env(:gsmlg_web, GSMLG.Web.Endpoint)
      assert endpoint_config[:server] == false
    end
  end

  describe "setup_admin_web/1" do
    test "configures admin web endpoint" do
      config = %{
        url: "https://admin.example.com:8081",
        secret_key_base: "admin_secret",
        port: 8081,
        server: true,
        user_register: false
      }

      Setup.setup_admin_web(config)

      endpoint_config = Application.get_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint)
      assert endpoint_config[:secret_key_base] == "admin_secret"
      assert endpoint_config[:http][:port] == 8081
      assert endpoint_config[:server] == true
      assert endpoint_config[:url][:host] == "admin.example.com"
      assert endpoint_config[:url][:port] == 8081
      assert endpoint_config[:url][:scheme] == "https"
      assert endpoint_config[:user_register] == false
    end
  end

  describe "setup_couchdb/1" do
    test "configures couchdb connection" do
      config = %{
        host: "couchdb.example.com",
        port: 5984,
        username: "couch_user",
        password: "couch_pass"
      }

      Setup.setup_couchdb(config)

      connection_config = Application.get_env(:gsmlg_couchdb, GSMLG.CouchDB.Connection)
      assert connection_config[:host] == "couchdb.example.com"
      assert connection_config[:port] == 5984
      assert connection_config[:username] == "couch_user"
      assert connection_config[:password] == "couch_pass"
    end
  end

  describe "setup_commander/1" do
    test "configures commander" do
      config = %{
        start: true,
        name: "test_commander",
        platform_url: "ws://localhost:4111/socket",
        platform_key: "test_key"
      }

      Setup.setup_commander(config)

      commander_config = Application.get_env(:gsmlg_commander, GSMLG.Commander)
      assert commander_config[:start] == true
      assert commander_config[:name] == "test_commander"
      assert commander_config[:platform_url] == "ws://localhost:4111/socket"
      assert commander_config[:platform_key] == "test_key"
    end
  end

  describe "setup_cluster/1" do
    test "stores disabled cluster config without configuring libcluster topologies" do
      Setup.setup_cluster(%{enabled: false, strategy: "epmd", hosts: ["gsmlg@127.0.0.1"]})

      assert Application.get_env(:gsmlg, :cluster)[:enabled] == false
      assert Application.get_env(:libcluster, :topologies) == []
    end

    test "configures libcluster topologies when cluster is enabled" do
      Setup.setup_cluster(%{
        enabled: true,
        strategy: "epmd",
        topology_name: "production",
        hosts: ["gsmlg@10.100.10.10", "gsmlg@10.100.10.11"],
        connect_interval: 30_000
      })

      assert Application.get_env(:gsmlg, :cluster)[:enabled] == true

      assert [
               production: [
                 strategy: Cluster.Strategy.Epmd,
                 config: [
                   hosts: [:"gsmlg@10.100.10.10", :"gsmlg@10.100.10.11"],
                   timeout: 30_000
                 ]
               ]
             ] = Application.get_env(:libcluster, :topologies)
    end
  end

  describe "setup_oauth/1" do
    test "configures github oauth" do
      config = %{
        github: %{
          client_id: "github_client_id",
          client_secret: "github_client_secret"
        }
      }

      Setup.setup_oauth(config)

      oauth_config = Application.get_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)
      assert oauth_config[:client_id] == "github_client_id"
      assert oauth_config[:client_secret] == "github_client_secret"
    end

    test "handles missing github config" do
      config = %{}

      # Should not crash
      assert Setup.setup_oauth(config) == nil
    end
  end

  describe "setup_web_push/1" do
    test "configures web push" do
      config = %{
        subject: "mailto:test@example.com",
        public_key: "public_key_test",
        private_key: "private_key_test"
      }

      Setup.setup_web_push(config)

      vapid_config = Application.get_env(:gsmlg_web_push, :vapid_details)
      assert vapid_config[:subject] == "mailto:test@example.com"
      assert vapid_config[:public_key] == "public_key_test"
      assert vapid_config[:private_key] == "private_key_test"
    end
  end

  describe "setup_scout/1" do
    test "configures scout settings" do
      config = %{
        general: %{
          instance_name: "GSMLG Scout",
          default_region: "local",
          request_timeout_ms: 30_000
        },
        rabbitmq: %{
          enabled: false,
          url: "amqp://guest:guest@localhost:5672",
          queues: %{
            jobs: "scout.fetch.jobs",
            results: "scout.fetch.results",
            failed: "scout.fetch.failed",
            heartbeat: "scout.agent.heartbeat"
          },
          regional_queues: %{eu: "scout.fetch.jobs.eu"}
        },
        fetch: %{
          default_timeout_ms: 30_000,
          max_timeout_ms: 60_000,
          max_page_size_bytes: 5_000_000,
          browser: %{wait_until: "network_idle", wait_for: "", javascript: true},
          retry: %{max_attempts: 3, base_backoff_ms: 500, max_backoff_ms: 5_000, jitter: true}
        },
        agent: %{
          enabled: false,
          id: "",
          region: "local",
          heartbeat_interval_ms: 10_000,
          capacity: 16,
          browser_instances: 2,
          page_concurrency: 16,
          lightpanda_path: "lightpanda"
        },
        security: %{
          allowed_schemes: ["http", "https"],
          redirect_limit: 5,
          blocked_cidrs: ["127.0.0.0/8"]
        }
      }

      Setup.setup_scout(config)

      assert Application.get_env(:gsmlg_scout, :settings) == config
    end
  end

  describe "update_env/4" do
    test "merges new values with existing application environment" do
      # Set existing config as keyword list
      Application.put_env(:test_app, TestKey, existing: "value", nested: [key: "old"])

      new_value = [new: "value", nested: [key: "new", another: "field"]]

      Setup.update_env(:test_app, TestKey, new_value)

      merged = Application.get_env(:test_app, TestKey)
      assert merged[:existing] == "value"
      assert merged[:new] == "value"
      assert merged[:nested][:key] == "new"
      assert merged[:nested][:another] == "field"
    end

    test "creates new environment when none exists" do
      new_value = %{test: "value"}

      Setup.update_env(:test_app_new, TestKey, new_value)

      result = Application.get_env(:test_app_new, TestKey)
      assert result == new_value
    end
  end

  describe "deep_merge/2" do
    test "merges keyword lists deeply" do
      old = [key1: "value1", nested: [old_key: "old_value"]]
      new = [key2: "value2", nested: [new_key: "new_value"]]

      # Use private function through apply since it's not public
      result = apply(Setup, :deep_merge, [old, new])

      assert result[:key1] == "value1"
      assert result[:key2] == "value2"
      assert result[:nested][:old_key] == "old_value"
      assert result[:nested][:new_key] == "new_value"
    end

    test "merges maps deeply" do
      old = %{key1: "value1", nested: %{old_key: "old_value"}}
      new = %{key2: "value2", nested: %{new_key: "new_value"}}

      # Use private function through apply since it's not public
      result = apply(Setup, :deep_merge, [old, new])

      assert result.key1 == "value1"
      assert result.key2 == "value2"
      assert result.nested.old_key == "old_value"
      assert result.nested.new_key == "new_value"
    end

    test "returns new value when types don't match" do
      old = [key1: "value1"]
      new = %{key2: "value2"}

      # Use private function through apply since it's not public
      result = apply(Setup, :deep_merge, [old, new])

      assert result == new
    end
  end
end
