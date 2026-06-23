defmodule GSMLG.Repo.Migrations.RemoveGaoNoteTagSlug do
  use Ecto.Migration

  def up do
    drop_if_exists unique_index(:gao_note_tags, [:slug])

    alter table(:gao_note_tags) do
      remove_if_exists :slug, :string
    end
  end

  def down do
    :ok
  end
end
