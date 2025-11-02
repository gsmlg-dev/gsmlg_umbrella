defmodule GSMLG.Repo.Migrations.FixGuardianTokensForPostgresql do
  use Ecto.Migration

  def change do
    # Clear existing Guardian JWT tokens from MySQL migration
    # The :map type (claims field) data was stored as JSON strings in MySQL
    # and needs to be cleared for PostgreSQL JSONB compatibility.
    # Users will need to log in again to generate new tokens.
    execute("TRUNCATE TABLE user_tokens;", "")
  end
end
