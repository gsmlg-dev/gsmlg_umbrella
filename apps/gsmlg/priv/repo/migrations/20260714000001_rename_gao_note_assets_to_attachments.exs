defmodule GSMLG.Repo.Migrations.RenameGaoNoteAssetsToAttachments do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF to_regclass('public.gao_note_assets') IS NOT NULL THEN
        ALTER TABLE public.gao_note_assets
          ADD COLUMN IF NOT EXISTS description text NOT NULL DEFAULT '';
        ALTER TABLE public.gao_note_assets
          ADD COLUMN IF NOT EXISTS path text;

        UPDATE public.gao_note_assets
        SET description = ''
        WHERE description IS NULL;

        ALTER TABLE public.gao_note_assets
          ALTER COLUMN description SET DEFAULT '',
          ALTER COLUMN description SET NOT NULL;
      END IF;

      IF to_regclass('public.gao_note_attachments') IS NOT NULL THEN
        ALTER TABLE public.gao_note_attachments
          ADD COLUMN IF NOT EXISTS description text NOT NULL DEFAULT '';
        ALTER TABLE public.gao_note_attachments
          ADD COLUMN IF NOT EXISTS path text;

        UPDATE public.gao_note_attachments
        SET description = ''
        WHERE description IS NULL;

        ALTER TABLE public.gao_note_attachments
          ALTER COLUMN description SET DEFAULT '',
          ALTER COLUMN description SET NOT NULL;
      END IF;

      IF to_regclass('public.gao_note_assets') IS NOT NULL
         AND to_regclass('public.gao_note_attachments') IS NOT NULL THEN
        DELETE FROM public.gao_note_attachments AS attachment
        USING public.gao_note_assets AS asset
        WHERE attachment.id = asset.id
           OR (
             attachment.note_id = asset.note_id
             AND attachment.storage_file_id = asset.storage_file_id
           )
           OR (
             asset.path IS NOT NULL
             AND attachment.note_id = asset.note_id
             AND attachment.path = asset.path
           );

        INSERT INTO public.gao_note_attachments (
          id,
          note_id,
          storage_file_id,
          role,
          description,
          path,
          caption,
          alt_text,
          position,
          metadata,
          inserted_at,
          updated_at
        )
        SELECT
          id,
          note_id,
          storage_file_id,
          role,
          description,
          path,
          caption,
          alt_text,
          position,
          metadata,
          inserted_at,
          updated_at
        FROM public.gao_note_assets;

        DROP TABLE public.gao_note_assets;
      ELSIF to_regclass('public.gao_note_assets') IS NOT NULL THEN
        ALTER TABLE public.gao_note_assets RENAME TO gao_note_attachments;
      END IF;

      IF to_regclass('public.storage_files') IS NOT NULL THEN
        UPDATE public.storage_files
        SET type = 'attachment'
        WHERE tenant = 'gao_note' AND type = 'asset';
      END IF;

      IF to_regclass('public.gao_note_attachments') IS NOT NULL THEN
        IF EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conrelid = to_regclass('public.gao_note_attachments')
            AND conname = 'gao_note_assets_pkey'
        ) THEN
          IF EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conrelid = to_regclass('public.gao_note_attachments')
              AND conname = 'gao_note_attachments_pkey'
          ) THEN
            ALTER TABLE public.gao_note_attachments
              DROP CONSTRAINT gao_note_assets_pkey;
          ELSE
            ALTER TABLE public.gao_note_attachments
              RENAME CONSTRAINT gao_note_assets_pkey TO gao_note_attachments_pkey;
          END IF;
        END IF;

        IF NOT EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conrelid = to_regclass('public.gao_note_attachments')
            AND conname = 'gao_note_attachments_pkey'
        ) THEN
          ALTER TABLE public.gao_note_attachments
            ADD CONSTRAINT gao_note_attachments_pkey PRIMARY KEY (id);
        END IF;

        IF EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conrelid = to_regclass('public.gao_note_attachments')
            AND conname = 'gao_note_assets_note_id_fkey'
        ) THEN
          IF EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conrelid = to_regclass('public.gao_note_attachments')
              AND conname = 'gao_note_attachments_note_id_fkey'
          ) THEN
            ALTER TABLE public.gao_note_attachments
              DROP CONSTRAINT gao_note_assets_note_id_fkey;
          ELSE
            ALTER TABLE public.gao_note_attachments
              RENAME CONSTRAINT gao_note_assets_note_id_fkey
              TO gao_note_attachments_note_id_fkey;
          END IF;
        END IF;

        IF NOT EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conrelid = to_regclass('public.gao_note_attachments')
            AND conname = 'gao_note_attachments_note_id_fkey'
        ) THEN
          ALTER TABLE public.gao_note_attachments
            ADD CONSTRAINT gao_note_attachments_note_id_fkey
            FOREIGN KEY (note_id) REFERENCES public.gao_notes(id) ON DELETE CASCADE;
        END IF;

        IF EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conrelid = to_regclass('public.gao_note_attachments')
            AND conname = 'gao_note_assets_storage_file_id_fkey'
        ) THEN
          IF EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conrelid = to_regclass('public.gao_note_attachments')
              AND conname = 'gao_note_attachments_storage_file_id_fkey'
          ) THEN
            ALTER TABLE public.gao_note_attachments
              DROP CONSTRAINT gao_note_assets_storage_file_id_fkey;
          ELSE
            ALTER TABLE public.gao_note_attachments
              RENAME CONSTRAINT gao_note_assets_storage_file_id_fkey
              TO gao_note_attachments_storage_file_id_fkey;
          END IF;
        END IF;

        IF NOT EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conrelid = to_regclass('public.gao_note_attachments')
            AND conname = 'gao_note_attachments_storage_file_id_fkey'
        ) THEN
          ALTER TABLE public.gao_note_attachments
            ADD CONSTRAINT gao_note_attachments_storage_file_id_fkey
            FOREIGN KEY (storage_file_id) REFERENCES public.storage_files(id) ON DELETE CASCADE;
        END IF;

        IF to_regclass('public.gao_note_assets_note_id_index') IS NOT NULL THEN
          IF to_regclass('public.gao_note_attachments_note_id_index') IS NULL THEN
            ALTER INDEX public.gao_note_assets_note_id_index
              RENAME TO gao_note_attachments_note_id_index;
          ELSE
            DROP INDEX public.gao_note_assets_note_id_index;
          END IF;
        END IF;

        IF to_regclass('public.gao_note_attachments_note_id_index') IS NULL THEN
          CREATE INDEX gao_note_attachments_note_id_index
            ON public.gao_note_attachments (note_id);
        END IF;

        IF to_regclass('public.gao_note_assets_storage_file_id_index') IS NOT NULL THEN
          IF to_regclass('public.gao_note_attachments_storage_file_id_index') IS NULL THEN
            ALTER INDEX public.gao_note_assets_storage_file_id_index
              RENAME TO gao_note_attachments_storage_file_id_index;
          ELSE
            DROP INDEX public.gao_note_assets_storage_file_id_index;
          END IF;
        END IF;

        IF to_regclass('public.gao_note_attachments_storage_file_id_index') IS NULL THEN
          CREATE INDEX gao_note_attachments_storage_file_id_index
            ON public.gao_note_attachments (storage_file_id);
        END IF;

        IF to_regclass('public.gao_note_assets_note_id_storage_file_id_index') IS NOT NULL THEN
          IF to_regclass('public.gao_note_attachments_note_id_storage_file_id_index') IS NULL THEN
            ALTER INDEX public.gao_note_assets_note_id_storage_file_id_index
              RENAME TO gao_note_attachments_note_id_storage_file_id_index;
          ELSE
            DROP INDEX public.gao_note_assets_note_id_storage_file_id_index;
          END IF;
        END IF;

        IF to_regclass('public.gao_note_attachments_note_id_storage_file_id_index') IS NULL THEN
          CREATE UNIQUE INDEX gao_note_attachments_note_id_storage_file_id_index
            ON public.gao_note_attachments (note_id, storage_file_id);
        END IF;

        IF to_regclass('public.gao_note_assets_note_id_path_index') IS NOT NULL THEN
          IF to_regclass('public.gao_note_attachments_note_id_path_index') IS NULL THEN
            ALTER INDEX public.gao_note_assets_note_id_path_index
              RENAME TO gao_note_attachments_note_id_path_index;
          ELSE
            DROP INDEX public.gao_note_assets_note_id_path_index;
          END IF;
        END IF;

        IF to_regclass('public.gao_note_attachments_note_id_path_index') IS NULL THEN
          CREATE UNIQUE INDEX gao_note_attachments_note_id_path_index
            ON public.gao_note_attachments (note_id, path)
            WHERE path IS NOT NULL;
        END IF;
      END IF;
    END $$;
    """)
  end

  def down do
    raise Ecto.MigrationError,
      "irreversible migration: legacy asset rows may replace conflicting attachment rows, " <>
        "the legacy table is dropped, and all GaoNote legacy asset storage rows are reclassified"
  end
end
