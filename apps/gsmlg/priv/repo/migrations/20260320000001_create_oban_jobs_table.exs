defmodule GSMLG.Repo.Migrations.CreateObanJobsTable do
  use Ecto.Migration

  def up do
    Styx.Migration.up(version: 1, prefix: prefix() || "public")
  end

  def down do
    migration_prefix = prefix() || "public"
    Styx.Migration.down(version: 1, prefix: migration_prefix)

    # The transition rollback restores these names on databases upgraded from Oban.
    drop_if_exists table(:oban_peers, prefix: migration_prefix)
    drop_if_exists table(:oban_jobs, prefix: migration_prefix)
    quoted_prefix = "\"#{String.replace(migration_prefix, "\"", "\"\"")}\""
    execute "DROP TYPE IF EXISTS #{quoted_prefix}.oban_job_state"
  end
end
