defmodule GSMLG.Repo.Migrations.AllowStringGaoNoteAuditEntityIds do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE gao_note_logs ALTER COLUMN entity_id TYPE text USING entity_id::text"
  end

  def down do
    execute "ALTER TABLE gao_note_logs ALTER COLUMN entity_id TYPE uuid USING entity_id::uuid"
  end
end
