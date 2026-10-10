defmodule GSMLG.Config.TestDatabaseConfigTest do
  use ExUnit.Case, async: false

  alias GSMLG.Config.Setup

  @database_env ~w(DATABASE_URL PGHOST PGPORT POSTGRES_HOST POSTGRES_PORT POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB MIX_TEST_PARTITION SKIP_SANDBOX_POOL MIX_ENV)

  setup do
    previous_env = Map.new(@database_env, &{&1, System.get_env(&1)})
    previous_repo = Application.fetch_env(:gsmlg, GSMLG.Repo)
    Enum.each(@database_env, &System.delete_env/1)
    System.put_env("MIX_ENV", "test")

    on_exit(fn ->
      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      case previous_repo do
        {:ok, config} -> Application.put_env(:gsmlg, GSMLG.Repo, config)
        :error -> Application.delete_env(:gsmlg, GSMLG.Repo)
      end
    end)

    :ok
  end

  test "devenv tests retain credentials, socket port and partition across repeated runtime setup" do
    System.put_env(%{
      "DATABASE_URL" => "postgres://gsmlg_dev:gsmlg_dev@localhost/gsmlg_dev",
      "PGHOST" => "/tmp/devenv-test-postgres",
      "PGPORT" => "5433",
      "MIX_TEST_PARTITION" => "2"
    })

    config = read_test_config()

    assert config[:url] == "postgres://gsmlg_dev:gsmlg_dev@localhost/gsmlg_test2"
    assert config[:socket_dir] == "/tmp/devenv-test-postgres"
    assert config[:port] == 5433
    assert config[:pool] == Ecto.Adapters.SQL.Sandbox

    Application.put_env(:gsmlg, GSMLG.Repo, config)

    # runtime.exs and GSMLG.Application.start/2 both apply the TOML defaults.
    for _ <- 1..2 do
      Setup.setup(%{database: %{username: "gsmlg_test", database: "gsmlg_test", port: 5432}})
      assert Application.get_env(:gsmlg, GSMLG.Repo) == config
    end
  end

  test "only the URL database changes and an explicit URL port takes precedence" do
    System.put_env(%{
      "DATABASE_URL" => "postgres://other:gsmlg_dev%40secret@db.example:5440/custom_dev?ssl=true",
      "PGPORT" => "5433",
      "POSTGRES_DB" => "isolated_test"
    })

    config = read_test_config()

    assert config[:url] ==
             "postgres://other:gsmlg_dev%40secret@db.example:5440/isolated_test?ssl=true"

    assert config[:port] == 5440
  end

  test "runtime TOML setup cannot redirect a configured Sandbox repo to the dev database" do
    System.put_env("DATABASE_URL", "postgres://gsmlg_dev:gsmlg_dev@localhost/gsmlg_dev")

    config = [
      url: "postgres://gsmlg_dev:gsmlg_dev@localhost/gsmlg_test2",
      pool: Ecto.Adapters.SQL.Sandbox,
      port: 5433
    ]

    Application.put_env(:gsmlg, GSMLG.Repo, config)
    Setup.setup(%{database: %{database: "gsmlg_test", port: 5432}})

    assert Application.get_env(:gsmlg, GSMLG.Repo) == config
  end

  test "test migration commands preserve their selected database and ConnectionPool" do
    System.put_env(%{
      "DATABASE_URL" => "postgres://gsmlg_dev:gsmlg_dev@localhost/gsmlg_dev",
      "PGHOST" => "/tmp/devenv-test-postgres",
      "PGPORT" => "5433",
      "MIX_TEST_PARTITION" => "3",
      "SKIP_SANDBOX_POOL" => "true"
    })

    config = read_test_config()

    assert config[:url] == "postgres://gsmlg_dev:gsmlg_dev@localhost/gsmlg_test3"
    assert config[:port] == 5433
    assert config[:pool] == DBConnection.ConnectionPool

    Application.put_env(:gsmlg, GSMLG.Repo, config)

    for _ <- 1..2 do
      Setup.setup(%{database: %{database: "gsmlg_test", port: 5432}})
      assert Application.get_env(:gsmlg, GSMLG.Repo) == config
    end
  end

  test "development and production still apply runtime database configuration" do
    System.put_env("DATABASE_URL", "postgres://runtime:runtime@localhost/runtime_db")

    for env <- ["dev", "prod"] do
      System.put_env("MIX_ENV", env)

      Application.put_env(:gsmlg, GSMLG.Repo,
        url: "postgres://gsmlg_dev:gsmlg_dev@localhost/gsmlg_test",
        pool: Ecto.Adapters.SQL.Sandbox
      )

      Setup.setup(%{database: %{database: "configured_db", port: 5432}})

      assert Application.get_env(:gsmlg, GSMLG.Repo)[:url] ==
               "postgres://runtime:runtime@localhost/runtime_db"
    end
  end

  test "TCP tests retain explicit POSTGRES credentials, port and database" do
    System.put_env(%{
      "POSTGRES_USER" => "ci_test",
      "POSTGRES_PASSWORD" => "ci_password",
      "POSTGRES_HOST" => "ci-postgres",
      "POSTGRES_PORT" => "5441",
      "POSTGRES_DB" => "ci_database"
    })

    config = read_test_config()

    assert config[:username] == "ci_test"
    assert config[:password] == "ci_password"
    assert config[:hostname] == "ci-postgres"
    assert config[:port] == 5441
    assert config[:database] == "ci_database"
    refute Keyword.has_key?(config, :socket_dir)
  end

  defp read_test_config do
    Path.expand("../../../../../config/test.exs", __DIR__)
    |> Config.Reader.read!(env: :test, target: :host)
    |> get_in([:gsmlg, GSMLG.Repo])
  end
end
