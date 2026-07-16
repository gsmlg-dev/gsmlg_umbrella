defmodule GSMLG.Repo.Migrations.CreateGaoNoteLabels do
  use Ecto.Migration

  def change do
    create table(:gao_note_labels, primary_key: false) do
      add :note_id, references(:gao_notes, type: :binary_id, on_delete: :delete_all), null: false

      add :label_setting_id,
          references(:gao_note_label_settings, type: :binary_id, on_delete: :delete_all),
          null: false

      add :value, :text
      add :status, :string, null: false, default: "valid"
      add :errors, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gao_note_labels, [:note_id, :label_setting_id])
    create index(:gao_note_labels, [:label_setting_id])
    create index(:gao_note_labels, [:status])
  end
end
