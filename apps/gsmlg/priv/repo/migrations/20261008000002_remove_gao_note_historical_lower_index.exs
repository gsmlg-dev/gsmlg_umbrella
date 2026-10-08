defmodule GSMLG.Repo.Migrations.RemoveGaoNoteHistoricalLowerIndex do
  use Ecto.Migration

  def up do
    # The original tag catalog was renamed without renaming its indexes.
    drop_if_exists index(:gao_note_label_settings, ["lower(name)"],
                     name: :gao_note_tags_lower_name_index
                   )
  end

  def down do
    create unique_index(:gao_note_label_settings, ["lower(name)"],
             name: :gao_note_tags_lower_name_index
           )
  end
end
