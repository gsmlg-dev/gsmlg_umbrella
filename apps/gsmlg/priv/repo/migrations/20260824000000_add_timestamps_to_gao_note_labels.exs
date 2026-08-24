defmodule GSMLG.Repo.Migrations.AddTimestampsToGaoNoteLabels do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE gao_note_labels
      ADD COLUMN IF NOT EXISTS inserted_at timestamp(6) without time zone,
      ADD COLUMN IF NOT EXISTS updated_at timestamp(6) without time zone
    """)

    execute("""
    UPDATE gao_note_labels
    SET inserted_at = COALESCE(inserted_at, NOW()),
        updated_at = COALESCE(updated_at, NOW())
    WHERE inserted_at IS NULL OR updated_at IS NULL
    """)

    execute("""
    ALTER TABLE gao_note_labels
      ALTER COLUMN inserted_at SET NOT NULL,
      ALTER COLUMN updated_at SET NOT NULL
    """)
  end

  def down do
    raise "GaoNote label timestamps are required by the persisted schema"
  end
end
