defmodule GSMLG.Repo.Migrations.ReplaceObanWithStyx do
  use Ecto.Migration

  @legacy_marker "gsmlg: migrated from Oban v14"

  def up do
    if table_exists?("oban_jobs") do
      if table_exists?("styx_jobs") do
        raise Ecto.MigrationError,
              "both oban_jobs and styx_jobs exist; refusing to overwrite queued jobs"
      end

      schema = quoted_prefix()

      # Oban v14 and Styx v1 have the same job columns and states. Renaming retains
      # every row, index and the owned ID sequence without rebuilding the queue.
      execute "ALTER TABLE #{schema}.oban_jobs RENAME TO styx_jobs"
      execute "ALTER TABLE #{schema}.oban_peers RENAME TO styx_peers"
      execute "ALTER TYPE #{schema}.oban_job_state RENAME TO styx_job_state"
      execute "COMMENT ON TABLE #{schema}.styx_jobs IS '1'"
      execute "COMMENT ON TABLE #{schema}.styx_peers IS '#{@legacy_marker}'"

      execute """
      CREATE OR REPLACE FUNCTION #{schema}.styx_wrap_id(value bigint) RETURNS int AS $$
      BEGIN
        RETURN (value % 2147483647)::int;
      END;
      $$ LANGUAGE plpgsql IMMUTABLE;
      """
    end
  end

  def down do
    # Fresh installations already use Styx in the initial migration. Only undo
    # this transition when the marker confirms that Oban tables were renamed.
    if migrated_from_oban?() do
      schema = quoted_prefix()
      execute "DROP FUNCTION #{schema}.styx_wrap_id(bigint)"
      execute "ALTER TABLE #{schema}.styx_jobs RENAME TO oban_jobs"
      execute "ALTER TABLE #{schema}.styx_peers RENAME TO oban_peers"
      execute "ALTER TYPE #{schema}.styx_job_state RENAME TO oban_job_state"
      execute "COMMENT ON TABLE #{schema}.oban_jobs IS '14'"
      execute "COMMENT ON TABLE #{schema}.oban_peers IS NULL"
    end
  end

  defp table_exists?(name) do
    %{rows: [[exists?]]} =
      repo().query!(
        "SELECT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = $1 AND tablename = $2)",
        [prefix() || "public", name]
      )

    exists?
  end

  defp migrated_from_oban? do
    %{rows: rows} =
      repo().query!(
        """
        SELECT obj_description(c.oid, 'pg_class')
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relname = 'styx_peers'
        """,
        [prefix() || "public"]
      )

    rows == [[@legacy_marker]]
  end

  defp quoted_prefix do
    escaped = String.replace(prefix() || "public", "\"", "\"\"")
    "\"#{escaped}\""
  end
end
