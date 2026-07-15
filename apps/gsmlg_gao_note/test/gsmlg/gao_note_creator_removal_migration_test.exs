defmodule GSMLG.GaoNote.CreatorRemovalMigrationTest do
  use ExUnit.Case, async: false

  @migration GSMLG.Repo.Migrations.DropGaoNoteCreatorFields
  @migration_path Path.expand(
                    "../../../gsmlg/priv/repo/migrations/20260715000000_drop_gao_note_creator_fields.exs",
                    __DIR__
                  )
  @migration_version 20_260_715_000_000
  @repeat_version @migration_version + 1

  @states [
    {"neither legacy field", [], []},
    {"creator only", [:creator], [:creator]},
    {"creator_id only", [:creator_id], [:creator_id]},
    {"both legacy fields", [:creator, :creator_id], [:creator, :creator_id]}
  ]

  defmodule MigrationRepo do
    use Ecto.Repo,
      otp_app: :gsmlg,
      adapter: Ecto.Adapters.Postgres
  end

  setup_all do
    unless Code.ensure_loaded?(@migration), do: Code.compile_file(@migration_path)
    :ok
  end

  test "actual Ecto migration removes either, both, or neither legacy field idempotently" do
    Enum.each(@states, fn {state_name, columns, indexes} ->
      with_disposable_repo(fn ->
        create_gao_notes!(columns, indexes)

        assert :ok == migrate_up(@migration_version),
               "first migration failed for #{state_name}"

        first_catalog = creator_catalog()
        assert_creator_removed!(first_catalog, state_name)
        assert migration_versions() == [@migration_version]

        assert :ok == migrate_up(@repeat_version),
               "repeat migration failed for #{state_name}"

        assert creator_catalog() == first_catalog,
               "repeat migration changed the final catalog for #{state_name}"

        assert migration_versions() == [@migration_version, @repeat_version]
      end)
    end)
  end

  test "actual Ecto down migration is irreversible" do
    with_disposable_repo(fn ->
      create_gao_notes!([:creator, :creator_id], [:creator, :creator_id])
      assert :ok == migrate_up(@migration_version)

      assert_raise Ecto.MigrationError,
                   ~r/data was intentionally discarded/,
                   fn ->
                     Ecto.Migrator.down(
                       MigrationRepo,
                       @migration_version,
                       @migration,
                       log: false,
                       log_migrations_sql: false
                     )
                   end

      assert_creator_removed!(creator_catalog(), "irreversible down")
      assert migration_versions() == [@migration_version]
    end)
  end

  defp migrate_up(version) do
    Ecto.Migrator.up(MigrationRepo, version, @migration,
      log: false,
      log_migrations_sql: false
    )
  end

  defp create_gao_notes!(columns, indexes) do
    sql!("CREATE TABLE public.gao_notes (id bigint PRIMARY KEY, title text NOT NULL)")
    sql!("INSERT INTO public.gao_notes (id, title) VALUES (1, 'preserved')")
    Enum.each(columns, &add_column!/1)
    Enum.each(indexes, &add_index!/1)
  end

  defp add_column!(:creator),
    do: sql!("ALTER TABLE public.gao_notes ADD COLUMN creator text")

  defp add_column!(:creator_id),
    do: sql!("ALTER TABLE public.gao_notes ADD COLUMN creator_id text")

  defp add_index!(:creator),
    do: sql!("CREATE INDEX gao_notes_creator_index ON public.gao_notes (creator)")

  defp add_index!(:creator_id),
    do: sql!("CREATE INDEX gao_notes_creator_id_index ON public.gao_notes (creator_id)")

  defp assert_creator_removed!(catalog, state_name) do
    assert catalog.columns == [], "legacy columns remain for #{state_name}"
    assert catalog.indexes == [], "legacy indexes remain for #{state_name}"
    assert catalog.title == "preserved", "unrelated note data changed for #{state_name}"
  end

  defp creator_catalog do
    %{
      columns:
        values!("""
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'gao_notes'
          AND column_name IN ('creator', 'creator_id')
        ORDER BY column_name
        """),
      indexes:
        values!("""
        SELECT indexname
        FROM pg_indexes
        WHERE schemaname = 'public'
          AND tablename = 'gao_notes'
          AND indexname IN ('gao_notes_creator_index', 'gao_notes_creator_id_index')
        ORDER BY indexname
        """),
      title: scalar!("SELECT title FROM public.gao_notes WHERE id = 1")
    }
  end

  defp migration_versions do
    values!("SELECT version FROM public.schema_migrations ORDER BY version")
  end

  defp values!(statement) do
    statement
    |> sql!()
    |> Map.fetch!(:rows)
    |> List.flatten()
  end

  defp scalar!(statement) do
    %Postgrex.Result{rows: [[value]]} = sql!(statement)
    value
  end

  defp sql!(statement) do
    Ecto.Adapters.SQL.query!(MigrationRepo, statement, [], log: false)
  end

  defp with_disposable_repo(test) do
    database = "gsmlg_gao_note_creator_#{System.unique_integer([:positive, :monotonic])}"
    config = disposable_database_config(database)
    storage_up!(config)

    try do
      {:ok, repo_pid} = MigrationRepo.start_link(config)

      try do
        test.()
      after
        GenServer.stop(repo_pid)
      end
    after
      storage_down!(config)
    end
  end

  defp disposable_database_config(database) do
    GSMLG.Repo.config()
    |> resolve_url()
    |> normalize_connection_target()
    |> Keyword.put(:database, database)
    |> Keyword.put(:pool, DBConnection.ConnectionPool)
    |> Keyword.put(:pool_size, 2)
  end

  defp resolve_url(config) do
    case Keyword.pop(config, :url) do
      {nil, config} ->
        config

      {url, config} when is_binary(url) ->
        config
        |> Keyword.delete(:socket_dir)
        |> Keyword.merge(Ecto.Repo.Supervisor.parse_url(url))
    end
  end

  defp normalize_connection_target(config) do
    case Keyword.get(config, :socket_dir) do
      socket_dir when is_binary(socket_dir) and socket_dir != "" ->
        Keyword.delete(config, :hostname)

      _ ->
        Keyword.delete(config, :socket_dir)
    end
  end

  defp storage_up!(config) do
    case Ecto.Adapters.Postgres.storage_up(config) do
      :ok ->
        :ok

      {:error, :already_up} ->
        raise "disposable database unexpectedly already exists: #{config[:database]}"

      {:error, reason} ->
        raise "failed to create disposable database #{config[:database]}: #{inspect(reason)}"
    end
  end

  defp storage_down!(config) do
    case Ecto.Adapters.Postgres.storage_down(config) do
      :ok ->
        :ok

      {:error, :already_down} ->
        raise "disposable database disappeared before cleanup: #{config[:database]}"

      {:error, reason} ->
        raise "failed to drop disposable database #{config[:database]}: #{inspect(reason)}"
    end
  end
end
