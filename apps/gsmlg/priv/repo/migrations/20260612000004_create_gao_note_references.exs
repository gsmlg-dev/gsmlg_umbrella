defmodule GSMLG.Repo.Migrations.CreateGaoNoteReferences do
  use Ecto.Migration

  def change do
    create table(:gao_note_references, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :note_id, references(:gao_notes, type: :binary_id, on_delete: :delete_all), null: false
      add :url, :text, null: false
      add :canonical_url, :text
      add :title, :string
      add :description, :text
      add :site_name, :string
      add :favicon_url, :text
      add :position, :integer, null: false, default: 0
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:gao_note_references, [:note_id])
    create index(:gao_note_references, [:canonical_url])

    create unique_index(:gao_note_references, [:note_id, :canonical_url],
             where: "canonical_url IS NOT NULL"
           )
  end
end
