defmodule GSMLG.Repo.Migrations.CreateGaoNoteLabelSettings do
  use Ecto.Migration

  def change do
    create table(:gao_note_label_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :color, :string
      add :description, :text, null: false, default: ""
      add :value_type, :string, null: false, default: "text"
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gao_note_label_settings, ["lower(name)"],
             name: :gao_note_label_settings_lower_name_index
           )

    create index(:gao_note_label_settings, [:value_type])
  end
end
