defmodule GSMLG.Repo.Migrations.CreateGaoNoteTags do
  use Ecto.Migration

  def change do
    create table(:gao_note_tags, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :color, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gao_note_tags, [:slug])
    create unique_index(:gao_note_tags, ["lower(name)"], name: :gao_note_tags_lower_name_index)
  end
end
