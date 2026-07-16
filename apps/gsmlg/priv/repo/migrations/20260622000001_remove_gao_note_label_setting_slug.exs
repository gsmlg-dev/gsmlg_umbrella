defmodule GSMLG.Repo.Migrations.RemoveGaoNoteLabelSettingSlug do
  use Ecto.Migration

  def up do
    drop_if_exists unique_index(:gao_note_label_settings, [:slug])

    alter table(:gao_note_label_settings) do
      remove_if_exists :slug, :string
    end
  end

  def down do
    :ok
  end
end
