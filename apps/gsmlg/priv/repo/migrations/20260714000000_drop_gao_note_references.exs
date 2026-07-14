defmodule GSMLG.Repo.Migrations.DropGaoNoteReferences do
  use Ecto.Migration

  def up do
    drop_if_exists(table(:gao_note_references))
  end

  def down do
    raise Ecto.MigrationError,
          "cannot reverse GaoNote Reference removal: deleted Reference rows cannot be reconstructed"
  end
end
