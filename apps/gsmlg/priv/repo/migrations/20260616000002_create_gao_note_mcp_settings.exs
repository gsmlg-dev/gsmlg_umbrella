defmodule GSMLG.Repo.Migrations.CreateGaoNoteMCPSettings do
  use Ecto.Migration

  def change do
    create table(:gao_note_mcp_settings, primary_key: false) do
      add :id, :string, primary_key: true
      add :api_key_hash, :string, null: false
      add :api_key_hint, :string, null: false
      add :actor_id, references(:users, type: :string, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:gao_note_mcp_settings, [:actor_id])
  end
end
