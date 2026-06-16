defmodule GSMLG.Repo.Migrations.CreateGaoNoteLogs do
  use Ecto.Migration

  def change do
    create table(:gao_note_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :action, :string, null: false
      add :entity_type, :string, null: false
      add :entity_id, :binary_id
      add :note_id, :binary_id
      add :actor_id, :string
      add :source, :string, null: false, default: "admin"
      add :details, :map, null: false, default: %{}

      timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
    end

    create index(:gao_note_logs, [:created_at])
    create index(:gao_note_logs, [:action])
    create index(:gao_note_logs, [:entity_type])
    create index(:gao_note_logs, [:note_id])
    create index(:gao_note_logs, [:actor_id])
  end
end
