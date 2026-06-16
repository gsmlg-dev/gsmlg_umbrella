defmodule GSMLG.Repo.Migrations.MakeGaoNoteDescriptionOptional do
  use Ecto.Migration

  def up do
    execute("UPDATE gao_notes SET description = '' WHERE description IS NULL")

    alter table(:gao_notes) do
      modify :description, :text, null: false, default: ""
    end
  end

  def down do
    alter table(:gao_notes) do
      modify :description, :text, null: false
    end
  end
end
