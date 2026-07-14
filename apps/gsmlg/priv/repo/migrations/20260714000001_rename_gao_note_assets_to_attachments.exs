defmodule GSMLG.Repo.Migrations.RenameGaoNoteAssetsToAttachments do
  use Ecto.Migration

  @up_sql """
  DO $migration$
  DECLARE
    conflict_asset_id uuid;
    conflict_attachment_id uuid;
    conflict_attachment_ids uuid[];
  BEGIN
    IF to_regclass('public.gao_note_assets') IS NOT NULL THEN
      IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'gao_note_assets'
          AND column_name = 'description'
      ) THEN
        ALTER TABLE public.gao_note_assets
          ADD COLUMN description text DEFAULT '' NOT NULL;
      END IF;

      IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'gao_note_assets'
          AND column_name = 'path'
      ) THEN
        ALTER TABLE public.gao_note_assets
          ADD COLUMN path text;
      END IF;

      UPDATE public.gao_note_assets
      SET description = ''
      WHERE description IS NULL;

      UPDATE public.gao_note_assets
      SET path = NULL
      WHERE path IS NOT NULL AND btrim(path) = '';

      ALTER TABLE public.gao_note_assets
        ALTER COLUMN description SET DEFAULT '',
        ALTER COLUMN description SET NOT NULL;
    END IF;

    IF to_regclass('public.gao_note_attachments') IS NOT NULL THEN
      IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'gao_note_attachments'
          AND column_name = 'description'
      ) THEN
        ALTER TABLE public.gao_note_attachments
          ADD COLUMN description text DEFAULT '' NOT NULL;
      END IF;

      IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'gao_note_attachments'
          AND column_name = 'path'
      ) THEN
        ALTER TABLE public.gao_note_attachments
          ADD COLUMN path text;
      END IF;

      UPDATE public.gao_note_attachments
      SET description = ''
      WHERE description IS NULL;

      UPDATE public.gao_note_attachments
      SET path = NULL
      WHERE path IS NOT NULL AND btrim(path) = '';

      ALTER TABLE public.gao_note_attachments
        ALTER COLUMN description SET DEFAULT '',
        ALTER COLUMN description SET NOT NULL;
    END IF;

    IF to_regclass('public.gao_note_assets') IS NOT NULL
       AND to_regclass('public.gao_note_attachments') IS NOT NULL THEN
      SELECT asset.id, array_agg(DISTINCT attachment.id ORDER BY attachment.id)
      INTO conflict_asset_id, conflict_attachment_ids
      FROM public.gao_note_assets AS asset
      JOIN public.gao_note_attachments AS attachment
        ON attachment.id = asset.id
        OR (
          attachment.note_id = asset.note_id
          AND attachment.storage_file_id = asset.storage_file_id
        )
        OR (
          asset.path IS NOT NULL
          AND attachment.note_id = asset.note_id
          AND attachment.path = asset.path
        )
      GROUP BY asset.id
      HAVING count(DISTINCT attachment.id) > 1
      ORDER BY asset.id
      LIMIT 1;

      IF conflict_asset_id IS NOT NULL THEN
        RAISE EXCEPTION
          'GaoNote attachment migration conflict: legacy asset % matches multiple attachment rows through different uniqueness keys: %',
          conflict_asset_id,
          conflict_attachment_ids;
      END IF;

      SELECT asset.id, attachment.id
      INTO conflict_asset_id, conflict_attachment_id
      FROM public.gao_note_assets AS asset
      JOIN public.gao_note_attachments AS attachment
        ON attachment.id = asset.id
      WHERE attachment.note_id IS DISTINCT FROM asset.note_id
         OR attachment.storage_file_id IS DISTINCT FROM asset.storage_file_id
      ORDER BY asset.id
      LIMIT 1;

      IF conflict_asset_id IS NOT NULL THEN
        RAISE EXCEPTION
          'GaoNote attachment migration conflict: legacy asset % has the same ID as attachment % but maps to a different note/storage identity',
          conflict_asset_id,
          conflict_attachment_id;
      END IF;

      SELECT asset.id, attachment.id
      INTO conflict_asset_id, conflict_attachment_id
      FROM public.gao_note_assets AS asset
      JOIN public.gao_note_attachments AS attachment
        ON attachment.note_id = asset.note_id
       AND attachment.storage_file_id = asset.storage_file_id
      WHERE attachment.id <> asset.id
      ORDER BY asset.id
      LIMIT 1;

      IF conflict_asset_id IS NOT NULL THEN
        RAISE EXCEPTION
          'GaoNote attachment migration conflict: legacy asset % has the same note/storage identity as attachment % but maps to a different ID',
          conflict_asset_id,
          conflict_attachment_id;
      END IF;

      SELECT asset.id, attachment.id
      INTO conflict_asset_id, conflict_attachment_id
      FROM public.gao_note_assets AS asset
      JOIN public.gao_note_attachments AS attachment
        ON attachment.note_id = asset.note_id
       AND asset.path IS NOT NULL
       AND attachment.path = asset.path
      WHERE attachment.id <> asset.id
      ORDER BY asset.id
      LIMIT 1;

      IF conflict_asset_id IS NOT NULL THEN
        RAISE EXCEPTION
          'GaoNote attachment migration conflict: legacy asset % has the same non-null note/path as attachment % but maps to a different ID',
          conflict_asset_id,
          conflict_attachment_id;
      END IF;

      UPDATE public.gao_note_attachments AS attachment
      SET role =
            CASE
              WHEN attachment.role IS NULL OR btrim(attachment.role) = ''
                THEN asset.role
              ELSE attachment.role
            END,
          description =
            CASE
              WHEN btrim(attachment.description) = ''
                   AND asset.description IS NOT NULL
                   AND btrim(asset.description) <> ''
                THEN asset.description
              ELSE attachment.description
            END,
          path =
            CASE
              WHEN attachment.path IS NULL
                   AND asset.path IS NOT NULL
                   AND NOT EXISTS (
                     SELECT 1
                     FROM public.gao_note_attachments AS other_attachment
                     WHERE other_attachment.id <> attachment.id
                       AND other_attachment.note_id = asset.note_id
                       AND other_attachment.path = asset.path
                   )
                THEN asset.path
              ELSE attachment.path
            END,
          caption =
            CASE
              WHEN (attachment.caption IS NULL OR btrim(attachment.caption) = '')
                   AND asset.caption IS NOT NULL
                   AND btrim(asset.caption) <> ''
                THEN asset.caption
              ELSE attachment.caption
            END,
          alt_text =
            CASE
              WHEN (attachment.alt_text IS NULL OR btrim(attachment.alt_text) = '')
                   AND asset.alt_text IS NOT NULL
                   AND btrim(asset.alt_text) <> ''
                THEN asset.alt_text
              ELSE attachment.alt_text
            END,
          position = COALESCE(attachment.position, asset.position),
          metadata =
            COALESCE(asset.metadata, '{}'::jsonb) ||
            COALESCE(attachment.metadata, '{}'::jsonb)
      FROM public.gao_note_assets AS asset
      WHERE attachment.id = asset.id
        AND attachment.note_id IS NOT DISTINCT FROM asset.note_id
        AND attachment.storage_file_id IS NOT DISTINCT FROM asset.storage_file_id;

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
        asset.id,
        asset.note_id,
        asset.storage_file_id,
        asset.role,
        asset.description,
        asset.path,
        asset.caption,
        asset.alt_text,
        asset.position,
        asset.metadata,
        asset.inserted_at,
        asset.updated_at
      FROM public.gao_note_assets AS asset
      WHERE NOT EXISTS (
        SELECT 1
        FROM public.gao_note_attachments AS attachment
        WHERE attachment.id = asset.id
           OR (
             attachment.note_id = asset.note_id
             AND attachment.storage_file_id = asset.storage_file_id
           )
           OR (
             asset.path IS NOT NULL
             AND attachment.note_id = asset.note_id
             AND attachment.path = asset.path
           )
      );

      DROP TABLE public.gao_note_assets;
    ELSIF to_regclass('public.gao_note_assets') IS NOT NULL THEN
      ALTER TABLE public.gao_note_assets RENAME TO gao_note_attachments;
    END IF;

    IF to_regclass('public.storage_files') IS NOT NULL THEN
      UPDATE public.storage_files
      SET type = 'attachment'
      WHERE tenant = 'gao_note'
        AND type = 'asset';
    END IF;

    IF to_regclass('public.gao_note_attachments') IS NOT NULL THEN
      IF EXISTS (
        SELECT 1
        FROM pg_constraint AS constraint_record
        JOIN pg_class AS table_record
          ON table_record.oid = constraint_record.conrelid
        JOIN pg_namespace AS namespace_record
          ON namespace_record.oid = table_record.relnamespace
        WHERE namespace_record.nspname = 'public'
          AND table_record.relname = 'gao_note_attachments'
          AND constraint_record.conname = 'gao_note_assets_pkey'
      ) THEN
        IF EXISTS (
          SELECT 1
          FROM pg_constraint AS constraint_record
          JOIN pg_class AS table_record
            ON table_record.oid = constraint_record.conrelid
          JOIN pg_namespace AS namespace_record
            ON namespace_record.oid = table_record.relnamespace
          WHERE namespace_record.nspname = 'public'
            AND table_record.relname = 'gao_note_attachments'
            AND constraint_record.conname = 'gao_note_attachments_pkey'
        ) THEN
          ALTER TABLE public.gao_note_attachments
            DROP CONSTRAINT gao_note_assets_pkey;
        ELSE
          ALTER TABLE public.gao_note_attachments
            RENAME CONSTRAINT gao_note_assets_pkey TO gao_note_attachments_pkey;
        END IF;
      END IF;

      IF EXISTS (
        SELECT 1
        FROM pg_constraint AS constraint_record
        JOIN pg_class AS table_record
          ON table_record.oid = constraint_record.conrelid
        JOIN pg_namespace AS namespace_record
          ON namespace_record.oid = table_record.relnamespace
        WHERE namespace_record.nspname = 'public'
          AND table_record.relname = 'gao_note_attachments'
          AND constraint_record.conname = 'gao_note_assets_note_id_fkey'
      ) THEN
        IF EXISTS (
          SELECT 1
          FROM pg_constraint AS constraint_record
          JOIN pg_class AS table_record
            ON table_record.oid = constraint_record.conrelid
          JOIN pg_namespace AS namespace_record
            ON namespace_record.oid = table_record.relnamespace
          WHERE namespace_record.nspname = 'public'
            AND table_record.relname = 'gao_note_attachments'
            AND constraint_record.conname = 'gao_note_attachments_note_id_fkey'
        ) THEN
          ALTER TABLE public.gao_note_attachments
            DROP CONSTRAINT gao_note_assets_note_id_fkey;
        ELSE
          ALTER TABLE public.gao_note_attachments
            RENAME CONSTRAINT gao_note_assets_note_id_fkey
            TO gao_note_attachments_note_id_fkey;
        END IF;
      END IF;

      IF EXISTS (
        SELECT 1
        FROM pg_constraint AS constraint_record
        JOIN pg_class AS table_record
          ON table_record.oid = constraint_record.conrelid
        JOIN pg_namespace AS namespace_record
          ON namespace_record.oid = table_record.relnamespace
        WHERE namespace_record.nspname = 'public'
          AND table_record.relname = 'gao_note_attachments'
          AND constraint_record.conname = 'gao_note_assets_storage_file_id_fkey'
      ) THEN
        IF EXISTS (
          SELECT 1
          FROM pg_constraint AS constraint_record
          JOIN pg_class AS table_record
            ON table_record.oid = constraint_record.conrelid
          JOIN pg_namespace AS namespace_record
            ON namespace_record.oid = table_record.relnamespace
          WHERE namespace_record.nspname = 'public'
            AND table_record.relname = 'gao_note_attachments'
            AND constraint_record.conname = 'gao_note_attachments_storage_file_id_fkey'
        ) THEN
          ALTER TABLE public.gao_note_attachments
            DROP CONSTRAINT gao_note_assets_storage_file_id_fkey;
        ELSE
          ALTER TABLE public.gao_note_attachments
            RENAME CONSTRAINT gao_note_assets_storage_file_id_fkey
            TO gao_note_attachments_storage_file_id_fkey;
        END IF;
      END IF;

      IF EXISTS (
        SELECT 1
        FROM pg_class AS index_record
        JOIN pg_namespace AS namespace_record
          ON namespace_record.oid = index_record.relnamespace
        JOIN pg_index AS index_metadata
          ON index_metadata.indexrelid = index_record.oid
        JOIN pg_class AS table_record
          ON table_record.oid = index_metadata.indrelid
        WHERE namespace_record.nspname = 'public'
          AND table_record.relname = 'gao_note_attachments'
          AND index_record.relname =
            'gao_note_assets_note_id_storage_file_id_index'
      ) THEN
        IF to_regclass(
             'public.gao_note_attachments_note_id_storage_file_id_index'
           ) IS NULL THEN
          ALTER INDEX public.gao_note_assets_note_id_storage_file_id_index
            RENAME TO gao_note_attachments_note_id_storage_file_id_index;
        ELSE
          DROP INDEX public.gao_note_assets_note_id_storage_file_id_index;
        END IF;
      END IF;

      IF EXISTS (
        SELECT 1
        FROM pg_class AS index_record
        JOIN pg_namespace AS namespace_record
          ON namespace_record.oid = index_record.relnamespace
        JOIN pg_index AS index_metadata
          ON index_metadata.indexrelid = index_record.oid
        JOIN pg_class AS table_record
          ON table_record.oid = index_metadata.indrelid
        WHERE namespace_record.nspname = 'public'
          AND table_record.relname = 'gao_note_attachments'
          AND index_record.relname = 'gao_note_assets_note_id_path_index'
      ) THEN
        IF to_regclass('public.gao_note_attachments_note_id_path_index') IS NULL THEN
          ALTER INDEX public.gao_note_assets_note_id_path_index
            RENAME TO gao_note_attachments_note_id_path_index;
        ELSE
          DROP INDEX public.gao_note_assets_note_id_path_index;
        END IF;
      END IF;

      IF to_regclass(
           'public.gao_note_attachments_note_id_storage_file_id_index'
         ) IS NULL THEN
        CREATE UNIQUE INDEX gao_note_attachments_note_id_storage_file_id_index
          ON public.gao_note_attachments (note_id, storage_file_id);
      END IF;

      IF to_regclass('public.gao_note_attachments_note_id_path_index') IS NULL THEN
        CREATE UNIQUE INDEX gao_note_attachments_note_id_path_index
          ON public.gao_note_attachments (note_id, path);
      END IF;

      UPDATE public.gao_note_attachments
      SET description = ''
      WHERE description IS NULL;

      UPDATE public.gao_note_attachments
      SET path = NULL
      WHERE path IS NOT NULL AND btrim(path) = '';

      ALTER TABLE public.gao_note_attachments
        ALTER COLUMN description SET DEFAULT '',
        ALTER COLUMN description SET NOT NULL;
    END IF;
  END
  $migration$;
  """

  def up, do: execute(@up_sql)

  @doc false
  def up_sql, do: @up_sql

  def down do
    raise Ecto.MigrationError,
          "cannot reverse GaoNote Attachment compatibility migration: legacy Asset rows were merged and dropped, and legacy storage-file types were converted without persistent provenance"
  end
end
