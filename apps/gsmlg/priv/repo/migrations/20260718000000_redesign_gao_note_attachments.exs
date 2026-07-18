defmodule GSMLG.Repo.Migrations.RedesignGaoNoteAttachments do
  use Ecto.Migration

  def up do
    drop table(:gao_note_attachments)

    create table(:gao_note_attachments, primary_key: false) do
      add :id, :text, primary_key: true

      add :note_id, references(:gao_notes, type: :binary_id, on_delete: :delete_all),
        null: false

      add :storage_file_id,
          references(:storage_files, type: :binary_id, on_delete: :restrict),
          null: false

      add :path, :text, null: false
      add :mime, :text, null: false
      add :description, :text, null: false, default: ""

      timestamps(type: :utc_datetime_usec)
    end

    create index(:gao_note_attachments, [:note_id])
    create unique_index(:gao_note_attachments, [:storage_file_id])
    create unique_index(:gao_note_attachments, [:note_id, :path])
  end

  def down do
    raise "the GaoNote attachment hard break is intentionally irreversible"
  end
end
