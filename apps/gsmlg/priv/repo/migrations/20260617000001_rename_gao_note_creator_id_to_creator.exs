defmodule GSMLG.Repo.Migrations.RenameGaoNoteCreatorIdToCreator do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE gao_notes DROP CONSTRAINT IF EXISTS gao_notes_creator_id_fkey")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'gao_notes' AND column_name = 'creator_id'
      ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'gao_notes' AND column_name = 'creator'
      ) THEN
        ALTER TABLE gao_notes RENAME COLUMN creator_id TO creator;
      END IF;

      IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'gao_notes' AND column_name = 'creator'
      ) THEN
        ALTER TABLE gao_notes ADD COLUMN creator character varying NOT NULL DEFAULT '';
      END IF;

      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'gao_notes' AND column_name = 'creator_id'
      ) THEN
        UPDATE gao_notes SET creator = COALESCE(NULLIF(creator, ''), creator_id, '');
        ALTER TABLE gao_notes DROP COLUMN creator_id;
      END IF;

      UPDATE gao_notes SET creator = '' WHERE creator IS NULL;
      ALTER TABLE gao_notes ALTER COLUMN creator SET DEFAULT '';
      ALTER TABLE gao_notes ALTER COLUMN creator SET NOT NULL;
    END $$;
    """)

    drop_if_exists index(:gao_notes, [:creator_id])
    create_if_not_exists index(:gao_notes, [:creator])
  end

  def down do
    :ok
  end
end
