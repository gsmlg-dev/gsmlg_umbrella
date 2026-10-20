defmodule GSMLG.Repo.ReplaceObanWithStyxTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias GSMLG.Repo

  @migration GSMLG.Repo.Migrations.ReplaceObanWithStyx
  @version 20_261_020_000_000
  @initial GSMLG.Repo.Migrations.CreateObanJobsTable
  @initial_version 20_260_320_000_001
  @historical_v14 GSMLG.Repo.Migrations.UpdateObanJobsToV14
  @historical_v14_version 20_260_612_000_000
  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20261020000000_replace_oban_with_styx.exs",
                    __DIR__
                  )

  defmodule CreateStyxTables do
    use Ecto.Migration

    def up, do: Styx.Migration.up(prefix: prefix())
    def down, do: Styx.Migration.down(prefix: prefix())
  end

  setup_all do
    for migration <- [
          "20260320000001_create_oban_jobs_table.exs",
          "20260612000000_update_oban_jobs_to_v14.exs"
        ] do
      Code.require_file(Path.expand("../../../priv/repo/migrations/#{migration}", __DIR__))
    end

    Application.ensure_all_started(:ecto_sql)
    Application.ensure_all_started(:postgrex)

    unless Process.whereis(Repo), do: start_supervised!(Repo)
    :ok
  end

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})
    prefix = "styx_transition_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{prefix}")
    %{prefix: prefix, opts: [prefix: prefix, log: false, migration_lock: false]}
  end

  test "preserves legacy jobs, peers and sequence and supports rollback", %{
    prefix: prefix,
    opts: opts
  } do
    create_legacy_schema(prefix, opts)
    states = ~w(available suspended scheduled executing retryable completed discarded cancelled)

    for state <- states do
      Repo.query!("""
      INSERT INTO #{prefix}.oban_jobs (state, worker, args, meta, tags, errors, attempt, priority)
      VALUES ('#{state}', 'GSMLG.Workers.BlogTranslationWorker', '{"blog_id":42}',
              '{"source":"legacy"}', ARRAY['translation'],
              ARRAY['{"attempt":1,"error":"retry"}'::jsonb], 1, 4)
      """)
    end

    Repo.query!("""
    INSERT INTO #{prefix}.oban_peers (name, node, started_at, expires_at)
    VALUES ('legacy', 'node@host', now(), now() + interval '1 minute')
    """)

    jobs = Repo.query!("SELECT * FROM #{prefix}.oban_jobs ORDER BY id").rows
    peers = Repo.query!("SELECT * FROM #{prefix}.oban_peers ORDER BY name").rows

    assert :ok = migrate(:up, opts)
    assert Repo.query!("SELECT * FROM #{prefix}.styx_jobs ORDER BY id").rows == jobs
    assert Repo.query!("SELECT * FROM #{prefix}.styx_peers ORDER BY name").rows == peers
    assert [["1"]] = Repo.query!("SELECT obj_description('#{prefix}.styx_jobs'::regclass)").rows
    assert [[1]] = Repo.query!("SELECT #{prefix}.styx_wrap_id(2147483648)").rows

    assert {:ok, %Styx.Job{id: 9}} =
             %{blog_id: 43}
             |> Styx.Job.new(worker: GSMLG.Workers.BlogTranslationWorker)
             |> Repo.insert(prefix: prefix)

    assert :ok = migrate(:down, opts)
    assert Enum.take(Repo.query!("SELECT * FROM #{prefix}.oban_jobs ORDER BY id").rows, 8) == jobs
    assert Repo.query!("SELECT * FROM #{prefix}.oban_peers ORDER BY name").rows == peers
    assert [["14"]] = Repo.query!("SELECT obj_description('#{prefix}.oban_jobs'::regclass)").rows
    assert [[9]] = Repo.query!("SELECT count(*) FROM #{prefix}.oban_jobs").rows

    assert :ok = migrate(:up, opts)
    assert [[9]] = Repo.query!("SELECT count(*) FROM #{prefix}.styx_jobs").rows
  end

  test "leaves fresh Styx installations intact on upgrade and rollback", %{
    prefix: prefix,
    opts: opts
  } do
    assert :ok = Ecto.Migrator.up(Repo, 1, CreateStyxTables, opts)
    Repo.query!("INSERT INTO #{prefix}.styx_jobs (worker) VALUES ('FreshWorker')")

    assert :ok = migrate(:up, opts)
    assert :ok = migrate(:down, opts)
    assert [["FreshWorker"]] = Repo.query!("SELECT worker FROM #{prefix}.styx_jobs").rows
    assert [["1"]] = Repo.query!("SELECT obj_description('#{prefix}.styx_jobs'::regclass)").rows
  end

  test "rejects a conflicting Styx table without modifying legacy jobs", %{
    prefix: prefix,
    opts: opts
  } do
    create_legacy_schema(prefix, opts)
    Repo.query!("CREATE TABLE #{prefix}.styx_jobs (id bigint)")

    assert_raise Ecto.MigrationError, ~r/both.*oban_jobs.*styx_jobs/, fn ->
      migrate(:up, opts)
    end
  end

  test "fresh historical migration chain supports full rollback and reapplication", %{
    prefix: prefix,
    opts: opts
  } do
    apply_historical_migrations(opts)
    assert :ok = migrate(:up, opts)
    assert :ok = migrate(:down, opts)
    rollback_historical_migrations(opts)
    assert_queue_storage_absent(prefix)

    apply_historical_migrations(opts)
    assert :ok = migrate(:up, opts)
    assert [["1"]] = Repo.query!("SELECT obj_description('#{prefix}.styx_jobs'::regclass)").rows
  end

  test "legacy transition and historical full rollback allow a fresh migration chain", %{
    prefix: prefix,
    opts: opts
  } do
    create_legacy_schema(prefix, opts)

    Repo.query!("""
    INSERT INTO #{prefix}.schema_migrations (version, inserted_at)
    VALUES (#{@initial_version}, now()), (#{@historical_v14_version}, now())
    """)

    assert :ok = migrate(:up, opts)
    assert :ok = migrate(:down, opts)
    rollback_historical_migrations(opts)
    assert_queue_storage_absent(prefix)

    apply_historical_migrations(opts)
    assert :ok = migrate(:up, opts)
    assert [["1"]] = Repo.query!("SELECT obj_description('#{prefix}.styx_jobs'::regclass)").rows
  end

  defp apply_historical_migrations(opts) do
    assert :ok = Ecto.Migrator.up(Repo, @initial_version, @initial, opts)
    assert :ok = Ecto.Migrator.up(Repo, @historical_v14_version, @historical_v14, opts)
  end

  defp rollback_historical_migrations(opts) do
    assert :ok = Ecto.Migrator.down(Repo, @historical_v14_version, @historical_v14, opts)
    assert :ok = Ecto.Migrator.down(Repo, @initial_version, @initial, opts)
  end

  defp assert_queue_storage_absent(prefix) do
    for table <- ~w(oban_jobs oban_peers styx_jobs styx_peers) do
      assert [[nil]] = Repo.query!("SELECT to_regclass('#{prefix}.#{table}')").rows
    end

    assert [[0]] =
             Repo.query!(
               """
               SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
               WHERE n.nspname = $1 AND t.typname IN ('oban_job_state', 'styx_job_state')
               """,
               [prefix]
             ).rows
  end

  defp create_legacy_schema(prefix, opts) do
    assert :ok = Ecto.Migrator.up(Repo, 1, CreateStyxTables, opts)
    Repo.query!("ALTER TABLE #{prefix}.styx_jobs RENAME TO oban_jobs")
    Repo.query!("ALTER TABLE #{prefix}.styx_peers RENAME TO oban_peers")
    Repo.query!("ALTER TYPE #{prefix}.styx_job_state RENAME TO oban_job_state")
    Repo.query!("ALTER SEQUENCE #{prefix}.styx_jobs_id_seq RENAME TO oban_jobs_id_seq")
    Repo.query!("DROP FUNCTION #{prefix}.styx_wrap_id(bigint)")
    Repo.query!("COMMENT ON TABLE #{prefix}.oban_jobs IS '14'")
  end

  defp migrate(direction, opts) do
    assert File.exists?(@migration_path), "the forward Oban-to-Styx migration must exist"
    Code.require_file(@migration_path)
    apply(Ecto.Migrator, direction, [Repo, @version, @migration, opts])
  end
end
