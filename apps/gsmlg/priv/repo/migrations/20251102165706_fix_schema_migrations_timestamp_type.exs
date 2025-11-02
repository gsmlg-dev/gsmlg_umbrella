defmodule GSMLG.Repo.Migrations.FixSchemaMigrationsTimestampType do
  use Ecto.Migration

  def up do
    # Fix schema_migrations.inserted_at to use TIMESTAMP WITHOUT TIME ZONE
    # This ensures compatibility with Ecto's NaiveDateTime timestamps
    execute("""
    ALTER TABLE schema_migrations
    ALTER COLUMN inserted_at TYPE TIMESTAMP WITHOUT TIME ZONE
    """)
  end

  def down do
    # Revert to TIMESTAMP (default behavior)
    execute("""
    ALTER TABLE schema_migrations
    ALTER COLUMN inserted_at TYPE TIMESTAMP
    """)
  end
end
