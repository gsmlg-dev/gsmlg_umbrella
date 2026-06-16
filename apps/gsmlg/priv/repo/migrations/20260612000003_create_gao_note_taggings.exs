defmodule GSMLG.Repo.Migrations.CreateGaoNoteTaggings do
  use Ecto.Migration

  def change do
    create table(:gao_note_taggings, primary_key: false) do
      add :note_id, references(:gao_notes, type: :binary_id, on_delete: :delete_all), null: false

      add :tag_id, references(:gao_note_tags, type: :binary_id, on_delete: :delete_all),
        null: false
    end

    create unique_index(:gao_note_taggings, [:note_id, :tag_id])
    create index(:gao_note_taggings, [:tag_id])
  end
end
