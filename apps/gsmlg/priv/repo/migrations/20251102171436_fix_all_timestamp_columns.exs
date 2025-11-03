defmodule GSMLG.Repo.Migrations.FixAllTimestampColumns do
  use Ecto.Migration

  def up do
    # Fix all timestamp columns to use TIMESTAMP WITHOUT TIME ZONE
    # This ensures compatibility with Ecto's NaiveDateTime for all tables

    # Common timestamp columns created by timestamps() macro
    tables_with_timestamps = [
      "blogs",
      "users",
      "user_tokens"
    ]

    for table <- tables_with_timestamps do
      execute("""
      ALTER TABLE #{table}
      ALTER COLUMN inserted_at TYPE TIMESTAMP WITHOUT TIME ZONE
      """)

      execute("""
      ALTER TABLE #{table}
      ALTER COLUMN updated_at TYPE TIMESTAMP WITHOUT TIME ZONE
      """)
    end

    # Fix users.active_time column (utc_datetime)
    execute("""
    ALTER TABLE users
    ALTER COLUMN active_time TYPE TIMESTAMP WITHOUT TIME ZONE
    """)

    # Fix user_tokens.exp column if it exists as timestamp
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'user_tokens'
        AND column_name = 'exp'
        AND data_type LIKE 'timestamp%'
      ) THEN
        ALTER TABLE user_tokens ALTER COLUMN exp TYPE TIMESTAMP WITHOUT TIME ZONE;
      END IF;
    END $$;
    """)
  end

  def down do
    # Revert to default TIMESTAMP (which may include time zone on some PostgreSQL configs)
    tables_with_timestamps = [
      "blogs",
      "users",
      "user_tokens"
    ]

    for table <- tables_with_timestamps do
      execute("""
      ALTER TABLE #{table}
      ALTER COLUMN inserted_at TYPE TIMESTAMP
      """)

      execute("""
      ALTER TABLE #{table}
      ALTER COLUMN updated_at TYPE TIMESTAMP
      """)
    end

    execute("""
    ALTER TABLE users
    ALTER COLUMN active_time TYPE TIMESTAMP
    """)
  end
end
