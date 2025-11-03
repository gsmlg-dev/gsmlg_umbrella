#!/usr/bin/env elixir

# Script to fix all timestamp columns to TIMESTAMP WITHOUT TIME ZONE
# Run with: mix run fix_timestamps.exs

IO.puts("Starting timestamp column fix...")

sqls = [
  "ALTER TABLE blogs ALTER COLUMN inserted_at TYPE TIMESTAMP WITHOUT TIME ZONE",
  "ALTER TABLE blogs ALTER COLUMN updated_at TYPE TIMESTAMP WITHOUT TIME ZONE",
  "ALTER TABLE users ALTER COLUMN inserted_at TYPE TIMESTAMP WITHOUT TIME ZONE",
  "ALTER TABLE users ALTER COLUMN updated_at TYPE TIMESTAMP WITHOUT TIME ZONE",
  "ALTER TABLE users ALTER COLUMN active_time TYPE TIMESTAMP WITHOUT TIME ZONE",
  "ALTER TABLE user_tokens ALTER COLUMN inserted_at TYPE TIMESTAMP WITHOUT TIME ZONE",
  "ALTER TABLE user_tokens ALTER COLUMN updated_at TYPE TIMESTAMP WITHOUT TIME ZONE",
  "INSERT INTO schema_migrations (version, inserted_at) VALUES (20251102171436, NOW()) ON CONFLICT (version) DO NOTHING"
]

Enum.each(sqls, fn sql ->
  IO.puts("Executing: #{String.slice(sql, 0, 60)}...")
  Ecto.Adapters.SQL.query!(GSMLG.Repo, sql)
  IO.puts("  ✓ Success")
end)

IO.puts("\n✅ All timestamp columns fixed successfully!")
IO.puts("You can now sign up users without errors.")
