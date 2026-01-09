defmodule GSMLG.Repo.Migrations.CreateUserTokens do
  use Ecto.Migration

  def change do
    create table(:user_tokens, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :token, :string
      add :token_type, :string
      add :create_time, :utc_datetime
      add :expire_at, :utc_datetime
      # Users table uses :string primary key (40 chars), so FK must match
      add :user_id, references(:users, on_delete: :nothing, type: :string)

      timestamps()
    end

    create index(:user_tokens, [:user_id])
    create unique_index(:user_tokens, [:token])
  end
end
