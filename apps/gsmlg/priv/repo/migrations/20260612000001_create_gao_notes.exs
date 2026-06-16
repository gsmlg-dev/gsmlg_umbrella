defmodule GSMLG.Repo.Migrations.CreateGaoNotes do
  use Ecto.Migration

  def change do
    create table(:gao_notes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :description, :text, null: false
      add :content, :text, null: false
      add :creator, :string, null: false, default: ""

      timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
    end

    create index(:gao_notes, [:creator])
  end
end
