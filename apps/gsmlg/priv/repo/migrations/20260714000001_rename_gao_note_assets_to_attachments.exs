defmodule GSMLG.Repo.Migrations.RenameGaoNoteAssetsToAttachments do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF to_regclass('public.gao_note_attachments') IS NULL
         AND to_regclass('public.gao_note_assets') IS NOT NULL THEN
        ALTER TABLE public.gao_note_assets RENAME TO gao_note_attachments;
      END IF;

      IF to_regclass('public.gao_note_attachments') IS NOT NULL
         AND to_regclass('public.gao_note_assets') IS NULL THEN
        IF EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conrelid = to_regclass('public.gao_note_attachments')
            AND conname = 'gao_note_assets_pkey'
        ) AND NOT EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conrelid = to_regclass('public.gao_note_attachments')
            AND conname = 'gao_note_attachments_pkey'
        ) THEN
          ALTER TABLE public.gao_note_attachments
            RENAME CONSTRAINT gao_note_assets_pkey TO gao_note_attachments_pkey;
        END IF;

        IF EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conrelid = to_regclass('public.gao_note_attachments')
            AND conname = 'gao_note_assets_note_id_fkey'
        ) AND NOT EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conrelid = to_regclass('public.gao_note_attachments')
            AND conname = 'gao_note_attachments_note_id_fkey'
        ) THEN
          ALTER TABLE public.gao_note_attachments
            RENAME CONSTRAINT gao_note_assets_note_id_fkey
            TO gao_note_attachments_note_id_fkey;
        END IF;

        IF EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conrelid = to_regclass('public.gao_note_attachments')
            AND conname = 'gao_note_assets_storage_file_id_fkey'
        ) AND NOT EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conrelid = to_regclass('public.gao_note_attachments')
            AND conname = 'gao_note_attachments_storage_file_id_fkey'
        ) THEN
          ALTER TABLE public.gao_note_attachments
            RENAME CONSTRAINT gao_note_assets_storage_file_id_fkey
            TO gao_note_attachments_storage_file_id_fkey;
        END IF;

        IF to_regclass('public.gao_note_assets_note_id_index') IS NOT NULL
           AND to_regclass('public.gao_note_attachments_note_id_index') IS NULL THEN
          ALTER INDEX public.gao_note_assets_note_id_index
            RENAME TO gao_note_attachments_note_id_index;
        END IF;

        IF to_regclass('public.gao_note_assets_storage_file_id_index') IS NOT NULL
           AND to_regclass('public.gao_note_attachments_storage_file_id_index') IS NULL THEN
          ALTER INDEX public.gao_note_assets_storage_file_id_index
            RENAME TO gao_note_attachments_storage_file_id_index;
        END IF;

        IF to_regclass('public.gao_note_assets_note_id_storage_file_id_index') IS NOT NULL
           AND to_regclass('public.gao_note_attachments_note_id_storage_file_id_index') IS NULL THEN
          ALTER INDEX public.gao_note_assets_note_id_storage_file_id_index
            RENAME TO gao_note_attachments_note_id_storage_file_id_index;
        END IF;

        IF to_regclass('public.gao_note_assets_note_id_path_index') IS NOT NULL
           AND to_regclass('public.gao_note_attachments_note_id_path_index') IS NULL THEN
          ALTER INDEX public.gao_note_assets_note_id_path_index
            RENAME TO gao_note_attachments_note_id_path_index;
        END IF;
      END IF;

      IF to_regclass('public.storage_files') IS NOT NULL THEN
        UPDATE public.storage_files
        SET type = 'attachment'
        WHERE tenant = 'gao_note' AND type = 'asset';
      END IF;
    END $$;
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF to_regclass('public.gao_note_assets') IS NULL
         AND to_regclass('public.gao_note_attachments') IS NOT NULL THEN
        ALTER TABLE public.gao_note_attachments RENAME TO gao_note_assets;
      END IF;

      IF to_regclass('public.gao_note_assets') IS NOT NULL
         AND to_regclass('public.gao_note_attachments') IS NULL THEN
        IF EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conrelid = to_regclass('public.gao_note_assets')
            AND conname = 'gao_note_attachments_pkey'
        ) AND NOT EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conrelid = to_regclass('public.gao_note_assets')
            AND conname = 'gao_note_assets_pkey'
        ) THEN
          ALTER TABLE public.gao_note_assets
            RENAME CONSTRAINT gao_note_attachments_pkey TO gao_note_assets_pkey;
        END IF;

        IF EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conrelid = to_regclass('public.gao_note_assets')
            AND conname = 'gao_note_attachments_note_id_fkey'
        ) AND NOT EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conrelid = to_regclass('public.gao_note_assets')
            AND conname = 'gao_note_assets_note_id_fkey'
        ) THEN
          ALTER TABLE public.gao_note_assets
            RENAME CONSTRAINT gao_note_attachments_note_id_fkey
            TO gao_note_assets_note_id_fkey;
        END IF;

        IF EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conrelid = to_regclass('public.gao_note_assets')
            AND conname = 'gao_note_attachments_storage_file_id_fkey'
        ) AND NOT EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conrelid = to_regclass('public.gao_note_assets')
            AND conname = 'gao_note_assets_storage_file_id_fkey'
        ) THEN
          ALTER TABLE public.gao_note_assets
            RENAME CONSTRAINT gao_note_attachments_storage_file_id_fkey
            TO gao_note_assets_storage_file_id_fkey;
        END IF;

        IF to_regclass('public.gao_note_attachments_note_id_index') IS NOT NULL
           AND to_regclass('public.gao_note_assets_note_id_index') IS NULL THEN
          ALTER INDEX public.gao_note_attachments_note_id_index
            RENAME TO gao_note_assets_note_id_index;
        END IF;

        IF to_regclass('public.gao_note_attachments_storage_file_id_index') IS NOT NULL
           AND to_regclass('public.gao_note_assets_storage_file_id_index') IS NULL THEN
          ALTER INDEX public.gao_note_attachments_storage_file_id_index
            RENAME TO gao_note_assets_storage_file_id_index;
        END IF;

        IF to_regclass('public.gao_note_attachments_note_id_storage_file_id_index') IS NOT NULL
           AND to_regclass('public.gao_note_assets_note_id_storage_file_id_index') IS NULL THEN
          ALTER INDEX public.gao_note_attachments_note_id_storage_file_id_index
            RENAME TO gao_note_assets_note_id_storage_file_id_index;
        END IF;

        IF to_regclass('public.gao_note_attachments_note_id_path_index') IS NOT NULL
           AND to_regclass('public.gao_note_assets_note_id_path_index') IS NULL THEN
          ALTER INDEX public.gao_note_attachments_note_id_path_index
            RENAME TO gao_note_assets_note_id_path_index;
        END IF;
      END IF;

      IF to_regclass('public.storage_files') IS NOT NULL THEN
        UPDATE public.storage_files
        SET type = 'asset'
        WHERE tenant = 'gao_note' AND type = 'attachment';
      END IF;
    END $$;
    """)
  end
end
