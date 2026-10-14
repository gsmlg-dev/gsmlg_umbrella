defmodule GSMLG.Repo.Migrations.RemoveStorageFileForeignKeys do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE gao_note_attachments
      DROP CONSTRAINT IF EXISTS gao_note_attachments_storage_file_id_fkey
    """)

    execute("""
    ALTER TABLE gao_note_sync_pins
      DROP CONSTRAINT IF EXISTS gao_note_sync_pins_storage_file_id_fkey;
    """)
  end

  def down do
    execute("""
    ALTER TABLE gao_note_attachments
      ADD CONSTRAINT gao_note_attachments_storage_file_id_fkey
      FOREIGN KEY (storage_file_id) REFERENCES storage_files(id)
      ON DELETE RESTRICT NOT VALID
    """)

    execute("""
    ALTER TABLE gao_note_sync_pins
      ADD CONSTRAINT gao_note_sync_pins_storage_file_id_fkey
      FOREIGN KEY (storage_file_id) REFERENCES storage_files(id)
      ON DELETE RESTRICT NOT VALID;
    """)
  end
end
