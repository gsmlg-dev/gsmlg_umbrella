defmodule GSMLG.Repo.Migrations.CreateGaoNoteAttachments do
  use Ecto.Migration

  def change do
    create table(:gao_note_attachments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :note_id, references(:gao_notes, type: :binary_id, on_delete: :delete_all), null: false

      add :storage_file_id, references(:storage_files, type: :binary_id, on_delete: :delete_all),
        null: false

      add :role, :string, null: false, default: "attachment"
      add :description, :text, null: false, default: ""
      add :path, :text
      add :caption, :text
      add :alt_text, :text
      add :position, :integer, null: false, default: 0
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:gao_note_attachments, [:note_id])
    create index(:gao_note_attachments, [:storage_file_id])
    create unique_index(:gao_note_attachments, [:note_id, :storage_file_id])
    create unique_index(:gao_note_attachments, [:note_id, :path], where: "path IS NOT NULL")
  end
end
