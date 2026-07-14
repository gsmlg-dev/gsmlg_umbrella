defmodule GSMLG.GaoNote.AttachmentMigrationTest do
  use ExUnit.Case, async: false

  @migration GSMLG.Repo.Migrations.RenameGaoNoteAssetsToAttachments
  @repo_root Path.expand("../../../..", __DIR__)
  @migration_file Path.join(
                    @repo_root,
                    "apps/gsmlg/priv/repo/migrations/20260714000001_rename_gao_note_assets_to_attachments.exs"
                  )

  unless Code.ensure_loaded?(@migration) do
    Code.compile_file(@migration_file)
  end

  @note_1 "10000000-0000-0000-0000-000000000001"
  @note_2 "10000000-0000-0000-0000-000000000002"
  @note_3 "10000000-0000-0000-0000-000000000003"

  @storage_1 "20000000-0000-0000-0000-000000000001"
  @storage_2 "20000000-0000-0000-0000-000000000002"
  @storage_3 "20000000-0000-0000-0000-000000000003"
  @storage_4 "20000000-0000-0000-0000-000000000004"
  @orphan_storage "20000000-0000-0000-0000-000000000005"
  @other_tenant_storage "20000000-0000-0000-0000-000000000006"

  @row_1 "30000000-0000-0000-0000-000000000001"
  @row_2 "30000000-0000-0000-0000-000000000002"

  @expected_locks "gao_note_assets,gao_note_attachments,storage_files"

  setup do
    database =
      "gao_note_attachment_migration_#{System.unique_integer([:positive, :monotonic])}"

    command!("createdb", [database])

    on_exit(fn ->
      case System.cmd("dropdb", ["--if-exists", database], stderr_to_stdout: true) do
        {_output, 0} ->
          :ok

        {output, status} ->
          raise "dropdb cleanup failed for #{database} with status #{status}:\n#{output}"
      end
    end)

    create_base_tables!(database)
    %{database: database}
  end

  test "fresh attachment persistence remains final", %{database: database} do
    execute_sql!(database, attachment_table_sql(:attachment))
    migrate!(database)

    assert query(database, "SELECT count(*) FROM gao_note_attachments") == "0"
    assert_final_state(database)
  end

  test "assets-only legacy schema adds missing columns and preserves rows", %{
    database: database
  } do
    execute_sql!(database, legacy_asset_table_sql())

    execute_sql!(
      database,
      legacy_row_sql("gao_note_assets", %{
        id: @row_1,
        note_id: @note_1,
        storage_file_id: @storage_1,
        caption: "legacy caption"
      })
    )

    assert query(
             database,
             """
             SELECT count(*)
             FROM information_schema.columns
             WHERE table_schema = 'public'
               AND table_name = 'gao_note_assets'
               AND column_name IN ('description', 'path')
             """
           ) == "0"

    migrate!(database)

    assert query(
             database,
             """
             SELECT description || '|' || COALESCE(path, '<null>') || '|' || caption
             FROM gao_note_attachments
             WHERE id = '#{@row_1}'
             """
           ) == "|<null>|legacy caption"

    assert_final_state(database)
  end

  test "attachments-only state normalizes legacy identifiers", %{database: database} do
    execute_sql!(database, attachment_table_sql(:asset))

    execute_sql!(
      database,
      row_sql("gao_note_attachments", %{
        id: @row_1,
        note_id: @note_1,
        storage_file_id: @storage_1,
        description: "native attachment",
        path: "./native.txt"
      })
    )

    migrate!(database)

    assert query(
             database,
             "SELECT description FROM gao_note_attachments WHERE id = '#{@row_1}'"
           ) == "native attachment"

    assert_final_state(database)
  end

  test "coexistence inserts every non-conflicting Asset", %{database: database} do
    prepare_coexistence!(database)

    execute_sql!(
      database,
      row_sql("gao_note_attachments", %{
        id: @row_1,
        note_id: @note_1,
        storage_file_id: @storage_4,
        description: "existing attachment",
        path: "./attachment.txt"
      })
    )

    execute_sql!(
      database,
      row_sql("gao_note_assets", %{
        id: @row_2,
        note_id: @note_2,
        storage_file_id: @storage_2,
        description: "legacy asset",
        path: "./asset.txt"
      })
    )

    migrate!(database)

    assert query(database, "SELECT count(*) FROM gao_note_attachments") == "2"

    assert query(
             database,
             """
             SELECT string_agg(description, '|' ORDER BY description)
             FROM gao_note_attachments
             """
           ) == "existing attachment|legacy asset"

    assert_final_state(database)
  end

  test "same-identity merge keeps Attachment values and fills safe missing values", %{
    database: database
  } do
    prepare_coexistence!(database)

    execute_sql!(
      database,
      row_sql("gao_note_assets", %{
        id: @row_1,
        note_id: @note_1,
        storage_file_id: @storage_1,
        role: "attachment",
        description: "legacy description",
        path: "./legacy.txt",
        caption: "legacy caption",
        alt_text: "legacy alt text",
        position: 3,
        metadata: ~s({"asset_only":"yes","shared":"asset"})
      })
    )

    execute_sql!(
      database,
      row_sql("gao_note_attachments", %{
        id: @row_1,
        note_id: @note_1,
        storage_file_id: @storage_1,
        role: "attachment",
        description: "",
        path: nil,
        caption: nil,
        alt_text: "attachment alt text",
        position: 9,
        metadata: ~s({"attachment_only":"yes","shared":"attachment"})
      })
    )

    migrate!(database)

    assert query(
             database,
             """
             SELECT concat_ws(
               '|',
               role,
               description,
               path,
               caption,
               alt_text,
               position::text,
               metadata->>'asset_only',
               metadata->>'attachment_only',
               metadata->>'shared'
             )
             FROM gao_note_attachments
             WHERE id = '#{@row_1}'
             """
           ) ==
             "attachment|legacy description|./legacy.txt|legacy caption|" <>
               "attachment alt text|9|yes|yes|attachment"

    assert query(database, "SELECT count(*) FROM gao_note_attachments") == "1"
    assert_final_state(database)
  end

  test "same ID with divergent note/storage identity rolls back", %{database: database} do
    prepare_coexistence!(database)

    execute_sql!(
      database,
      row_sql("gao_note_assets", %{
        id: @row_1,
        note_id: @note_1,
        storage_file_id: @storage_1,
        path: "./asset.txt"
      })
    )

    execute_sql!(
      database,
      row_sql("gao_note_attachments", %{
        id: @row_1,
        note_id: @note_2,
        storage_file_id: @storage_2,
        path: "./attachment.txt"
      })
    )

    assert_conflict_rolls_back(
      database,
      "same ID as attachment #{@row_1} but maps to a different note/storage identity"
    )
  end

  test "same note/storage with a different ID rolls back", %{database: database} do
    prepare_coexistence!(database)

    execute_sql!(
      database,
      row_sql("gao_note_assets", %{
        id: @row_1,
        note_id: @note_1,
        storage_file_id: @storage_1,
        path: "./asset.txt"
      })
    )

    execute_sql!(
      database,
      row_sql("gao_note_attachments", %{
        id: @row_2,
        note_id: @note_1,
        storage_file_id: @storage_1,
        path: "./attachment.txt"
      })
    )

    assert_conflict_rolls_back(
      database,
      "same note/storage identity as attachment #{@row_2} but maps to a different ID"
    )
  end

  test "same non-null note/path with a different ID rolls back", %{database: database} do
    prepare_coexistence!(database)

    execute_sql!(
      database,
      row_sql("gao_note_assets", %{
        id: @row_1,
        note_id: @note_1,
        storage_file_id: @storage_1,
        path: "./same.txt"
      })
    )

    execute_sql!(
      database,
      row_sql("gao_note_attachments", %{
        id: @row_2,
        note_id: @note_1,
        storage_file_id: @storage_2,
        path: "./same.txt"
      })
    )

    assert_conflict_rolls_back(
      database,
      "same non-null note/path as attachment #{@row_2} but maps to a different ID"
    )
  end

  test "one Asset matching multiple Attachment rows rolls back", %{database: database} do
    prepare_coexistence!(database)

    execute_sql!(
      database,
      row_sql("gao_note_assets", %{
        id: @row_1,
        note_id: @note_1,
        storage_file_id: @storage_1,
        path: "./second.txt"
      })
    )

    execute_sql!(
      database,
      row_sql("gao_note_attachments", %{
        id: @row_1,
        note_id: @note_2,
        storage_file_id: @storage_2,
        path: "./first.txt"
      })
    )

    execute_sql!(
      database,
      row_sql("gao_note_attachments", %{
        id: @row_2,
        note_id: @note_1,
        storage_file_id: @storage_1,
        path: "./second.txt"
      })
    )

    assert_conflict_rolls_back(
      database,
      "matches multiple attachment rows through different uniqueness keys"
    )
  end

  test "projected set rejects duplicate paths among malformed Assets", %{
    database: database
  } do
    prepare_coexistence!(database)
    drop_asset_path_index!(database)

    execute_sql!(
      database,
      row_sql("gao_note_assets", %{
        id: @row_1,
        note_id: @note_1,
        storage_file_id: @storage_1,
        path: "./duplicate.txt"
      })
    )

    execute_sql!(
      database,
      row_sql("gao_note_assets", %{
        id: @row_2,
        note_id: @note_1,
        storage_file_id: @storage_2,
        path: "./duplicate.txt"
      })
    )

    assert_conflict_rolls_back(database, "projected final path collision")
  end

  test "projected set rejects duplicate paths from two merge candidates", %{
    database: database
  } do
    prepare_coexistence!(database)
    drop_asset_path_index!(database)

    execute_sql!(
      database,
      row_sql("gao_note_assets", %{
        id: @row_1,
        note_id: @note_1,
        storage_file_id: @storage_1,
        path: "./projected.txt"
      })
    )

    execute_sql!(
      database,
      row_sql("gao_note_assets", %{
        id: @row_2,
        note_id: @note_1,
        storage_file_id: @storage_2,
        path: "./projected.txt"
      })
    )

    execute_sql!(
      database,
      row_sql("gao_note_attachments", %{
        id: @row_1,
        note_id: @note_1,
        storage_file_id: @storage_1,
        path: nil
      })
    )

    execute_sql!(
      database,
      row_sql("gao_note_attachments", %{
        id: @row_2,
        note_id: @note_1,
        storage_file_id: @storage_2,
        path: nil
      })
    )

    assert_conflict_rolls_back(database, "projected final path collision")
  end

  test "projected set rejects a merge candidate colliding with an unmatched Asset", %{
    database: database
  } do
    prepare_coexistence!(database)
    drop_asset_path_index!(database)

    execute_sql!(
      database,
      row_sql("gao_note_assets", %{
        id: @row_1,
        note_id: @note_1,
        storage_file_id: @storage_1,
        path: "./projected.txt"
      })
    )

    execute_sql!(
      database,
      row_sql("gao_note_assets", %{
        id: @row_2,
        note_id: @note_1,
        storage_file_id: @storage_2,
        path: "./projected.txt"
      })
    )

    execute_sql!(
      database,
      row_sql("gao_note_attachments", %{
        id: @row_1,
        note_id: @note_1,
        storage_file_id: @storage_1,
        path: nil
      })
    )

    assert_conflict_rolls_back(database, "projected final path collision")
  end

  test "source accounting prevents a silently skipped Asset", %{database: database} do
    prepare_coexistence!(database)

    execute_sql!(
      database,
      row_sql("gao_note_assets", %{
        id: @row_1,
        note_id: @note_1,
        storage_file_id: @storage_1,
        path: "./suppressed.txt"
      })
    )

    execute_sql!(
      database,
      """
      CREATE FUNCTION suppress_legacy_asset_insert()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $trigger$
      BEGIN
        IF NEW.id = '#{@row_1}'::uuid THEN
          RETURN NULL;
        END IF;

        RETURN NEW;
      END
      $trigger$;

      CREATE TRIGGER suppress_legacy_asset_insert
      BEFORE INSERT ON public.gao_note_attachments
      FOR EACH ROW
      EXECUTE FUNCTION suppress_legacy_asset_insert();
      """
    )

    assert_conflict_rolls_back(database, "source accounting failed")
  end

  test "cutover holds ACCESS EXCLUSIVE locks through the transaction", %{
    database: database
  } do
    prepare_coexistence!(database)

    task =
      Task.async(fn ->
        execute_sql(
          database,
          "BEGIN;\n" <> @migration.up_sql() <> "\nSELECT pg_sleep(3);\nCOMMIT;"
        )
      end)

    lock_names = wait_for_cutover_locks(database, 50)
    {output, status} = Task.await(task, 6_000)

    assert status == 0, output
    assert lock_names == @expected_locks
    assert_final_state(database)
  end

  defp prepare_coexistence!(database) do
    execute_sql!(database, expanded_asset_table_sql())
    execute_sql!(database, attachment_table_sql(:attachment))
  end

  defp drop_asset_path_index!(database) do
    execute_sql!(database, "DROP INDEX public.gao_note_assets_note_id_path_index")
  end

  defp assert_conflict_rolls_back(database, expected_message) do
    asset_fingerprint = table_fingerprint(database, "gao_note_assets")
    attachment_fingerprint = table_fingerprint(database, "gao_note_attachments")
    storage_fingerprint = table_fingerprint(database, "storage_files")

    {output, status} = execute_sql(database, @migration.up_sql())

    refute status == 0
    assert output =~ expected_message
    assert query(database, "SELECT to_regclass('public.gao_note_assets') IS NOT NULL") == "t"

    assert query(
             database,
             "SELECT to_regclass('public.gao_note_attachments') IS NOT NULL"
           ) == "t"

    assert table_fingerprint(database, "gao_note_assets") == asset_fingerprint
    assert table_fingerprint(database, "gao_note_attachments") == attachment_fingerprint
    assert table_fingerprint(database, "storage_files") == storage_fingerprint
  end

  defp assert_final_state(database) do
    assert query(database, "SELECT to_regclass('public.gao_note_assets') IS NULL") == "t"

    assert query(
             database,
             "SELECT to_regclass('public.gao_note_attachments') IS NOT NULL"
           ) == "t"

    assert query(
             database,
             """
             SELECT string_agg(constraint_record.conname, ',' ORDER BY constraint_record.conname)
             FROM pg_constraint AS constraint_record
             JOIN pg_class AS table_record
               ON table_record.oid = constraint_record.conrelid
             JOIN pg_namespace AS namespace_record
               ON namespace_record.oid = table_record.relnamespace
             WHERE namespace_record.nspname = 'public'
               AND table_record.relname = 'gao_note_attachments'
             """
           ) ==
             "gao_note_attachments_note_id_fkey,gao_note_attachments_pkey," <>
               "gao_note_attachments_storage_file_id_fkey"

    assert query(
             database,
             """
             SELECT string_agg(indexname, ',' ORDER BY indexname)
             FROM pg_indexes
             WHERE schemaname = 'public'
               AND tablename = 'gao_note_attachments'
             """
           ) ==
             "gao_note_attachments_note_id_index," <>
               "gao_note_attachments_note_id_path_index," <>
               "gao_note_attachments_note_id_storage_file_id_index," <>
               "gao_note_attachments_pkey," <>
               "gao_note_attachments_storage_file_id_index"

    assert query(
             database,
             """
             SELECT concat_ws(
               '|',
               (
                 SELECT (
                   NOT index_metadata.indisunique
                   AND index_metadata.indpred IS NULL
                 )::text
                 FROM pg_index AS index_metadata
                 WHERE index_metadata.indexrelid =
                   to_regclass('public.gao_note_attachments_note_id_index')
               ),
               (
                 SELECT (
                   NOT index_metadata.indisunique
                   AND index_metadata.indpred IS NULL
                 )::text
                 FROM pg_index AS index_metadata
                 WHERE index_metadata.indexrelid =
                   to_regclass('public.gao_note_attachments_storage_file_id_index')
               ),
               (
                 SELECT (
                   index_metadata.indisunique
                   AND index_metadata.indpred IS NULL
                 )::text
                 FROM pg_index AS index_metadata
                 WHERE index_metadata.indexrelid =
                   to_regclass(
                     'public.gao_note_attachments_note_id_storage_file_id_index'
                   )
               ),
               (
                 SELECT (
                   index_metadata.indisunique
                   AND index_metadata.indpred IS NOT NULL
                   AND regexp_replace(
                     pg_get_expr(index_metadata.indpred, index_metadata.indrelid),
                     '[()]',
                     '',
                     'g'
                   ) = 'path IS NOT NULL'
                 )::text
                 FROM pg_index AS index_metadata
                 WHERE index_metadata.indexrelid =
                   to_regclass('public.gao_note_attachments_note_id_path_index')
               )
             )
             """
           ) == "true|true|true|true"

    assert query(
             database,
             """
             SELECT concat_ws(
               '|',
               (
                 SELECT (
                   is_nullable = 'NO'
                   AND data_type = 'character varying'
                   AND column_default =
                     quote_literal('attachment') || '::character varying'
                 )::text
                 FROM information_schema.columns
                 WHERE table_schema = 'public'
                   AND table_name = 'gao_note_attachments'
                   AND column_name = 'role'
               ),
               (
                 SELECT (
                   is_nullable = 'NO'
                   AND data_type = 'text'
                   AND column_default = quote_literal('') || '::text'
                 )::text
                 FROM information_schema.columns
                 WHERE table_schema = 'public'
                   AND table_name = 'gao_note_attachments'
                   AND column_name = 'description'
               ),
               (
                 SELECT (
                   is_nullable = 'YES'
                   AND data_type = 'text'
                   AND column_default IS NULL
                 )::text
                 FROM information_schema.columns
                 WHERE table_schema = 'public'
                   AND table_name = 'gao_note_attachments'
                   AND column_name = 'path'
               ),
               (
                 SELECT (
                   is_nullable = 'NO'
                   AND data_type = 'integer'
                   AND column_default = '0'
                 )::text
                 FROM information_schema.columns
                 WHERE table_schema = 'public'
                   AND table_name = 'gao_note_attachments'
                   AND column_name = 'position'
               ),
               (
                 SELECT (
                   is_nullable = 'NO'
                   AND data_type = 'jsonb'
                   AND column_default = quote_literal('{}') || '::jsonb'
                 )::text
                 FROM information_schema.columns
                 WHERE table_schema = 'public'
                   AND table_name = 'gao_note_attachments'
                   AND column_name = 'metadata'
               ),
               (
                 SELECT (
                   is_nullable = 'NO'
                   AND data_type = 'timestamp without time zone'
                   AND datetime_precision = 6
                   AND column_default IS NULL
                 )::text
                 FROM information_schema.columns
                 WHERE table_schema = 'public'
                   AND table_name = 'gao_note_attachments'
                   AND column_name = 'inserted_at'
               )
             )
             """
           ) == "true|true|true|true|true|true"

    assert query(
             database,
             """
             SELECT (
               count(*) = 12
               AND bool_and(
                 CASE
                   WHEN column_name IN ('id', 'note_id', 'storage_file_id') THEN
                     is_nullable = 'NO'
                     AND data_type = 'uuid'
                     AND column_default IS NULL
                   WHEN column_name = 'role' THEN
                     is_nullable = 'NO'
                     AND data_type = 'character varying'
                     AND column_default =
                       quote_literal('attachment') || '::character varying'
                   WHEN column_name = 'description' THEN
                     is_nullable = 'NO'
                     AND data_type = 'text'
                     AND column_default = quote_literal('') || '::text'
                   WHEN column_name IN ('path', 'caption', 'alt_text') THEN
                     is_nullable = 'YES'
                     AND data_type = 'text'
                     AND column_default IS NULL
                   WHEN column_name = 'position' THEN
                     is_nullable = 'NO'
                     AND data_type = 'integer'
                     AND column_default = '0'
                   WHEN column_name = 'metadata' THEN
                     is_nullable = 'NO'
                     AND data_type = 'jsonb'
                     AND column_default = quote_literal('{}') || '::jsonb'
                   WHEN column_name IN ('inserted_at', 'updated_at') THEN
                     is_nullable = 'NO'
                     AND data_type = 'timestamp without time zone'
                     AND datetime_precision = 6
                     AND column_default IS NULL
                   ELSE false
                 END
               )
             )::text
             FROM information_schema.columns
             WHERE table_schema = 'public'
               AND table_name = 'gao_note_attachments'
               AND column_name IN (
                 'id',
                 'note_id',
                 'storage_file_id',
                 'role',
                 'description',
                 'path',
                 'caption',
                 'alt_text',
                 'position',
                 'metadata',
                 'inserted_at',
                 'updated_at'
               )
             """
           ) == "true"

    assert query(
             database,
             """
             SELECT string_agg(
               constraint_record.conname || ':' || constraint_record.confdeltype::text,
               ','
               ORDER BY constraint_record.conname
             )
             FROM pg_constraint AS constraint_record
             JOIN pg_class AS table_record
               ON table_record.oid = constraint_record.conrelid
             JOIN pg_namespace AS namespace_record
               ON namespace_record.oid = table_record.relnamespace
             WHERE namespace_record.nspname = 'public'
               AND table_record.relname = 'gao_note_attachments'
               AND constraint_record.contype = 'f'
             """
           ) ==
             "gao_note_attachments_note_id_fkey:c," <>
               "gao_note_attachments_storage_file_id_fkey:c"

    assert query(
             database,
             """
             SELECT count(*)
             FROM storage_files
             WHERE tenant = 'gao_note'
               AND type = 'asset'
             """
           ) == "0"

    assert query(
             database,
             "SELECT type FROM storage_files WHERE id = '#{@orphan_storage}'"
           ) == "attachment"

    assert query(
             database,
             "SELECT type FROM storage_files WHERE id = '#{@other_tenant_storage}'"
           ) == "asset"
  end

  defp wait_for_cutover_locks(database, 0), do: cutover_lock_names(database)

  defp wait_for_cutover_locks(database, attempts) do
    case cutover_lock_names(database) do
      @expected_locks ->
        @expected_locks

      _other ->
        Process.sleep(50)
        wait_for_cutover_locks(database, attempts - 1)
    end
  end

  defp cutover_lock_names(database) do
    query(
      database,
      """
      SELECT COALESCE(
        string_agg(
          DISTINCT table_record.relname,
          ','
          ORDER BY table_record.relname
        ),
        ''
      )
      FROM pg_locks AS lock_record
      JOIN pg_class AS table_record
        ON table_record.oid = lock_record.relation
      WHERE lock_record.database = (
        SELECT oid
        FROM pg_database
        WHERE datname = current_database()
      )
        AND lock_record.pid <> pg_backend_pid()
        AND lock_record.mode = 'AccessExclusiveLock'
        AND lock_record.granted
        AND table_record.relname IN (
          'gao_note_assets',
          'gao_note_attachments',
          'storage_files'
        )
      """
    )
  end

  defp create_base_tables!(database) do
    execute_sql!(
      database,
      """
      CREATE TABLE public.gao_notes (
        id uuid PRIMARY KEY
      );

      CREATE TABLE public.storage_files (
        id uuid PRIMARY KEY,
        tenant text NOT NULL,
        type text NOT NULL
      );

      INSERT INTO public.gao_notes (id)
      VALUES
        ('#{@note_1}'),
        ('#{@note_2}'),
        ('#{@note_3}');

      INSERT INTO public.storage_files (id, tenant, type)
      VALUES
        ('#{@storage_1}', 'gao_note', 'asset'),
        ('#{@storage_2}', 'gao_note', 'asset'),
        ('#{@storage_3}', 'gao_note', 'asset'),
        ('#{@storage_4}', 'gao_note', 'attachment'),
        ('#{@orphan_storage}', 'gao_note', 'asset'),
        ('#{@other_tenant_storage}', 'other', 'asset');
      """
    )
  end

  # Mirrors the pre-hard-break 20260612000005 CreateGaoNoteAssets migration
  # from 544f332^: no description/path columns, cascade FKs, and three indexes.
  defp legacy_asset_table_sql do
    """
    CREATE TABLE public.gao_note_assets (
      id uuid NOT NULL,
      note_id uuid NOT NULL,
      storage_file_id uuid NOT NULL,
      role varchar(255) DEFAULT 'attachment' NOT NULL,
      caption text,
      alt_text text,
      position integer DEFAULT 0 NOT NULL,
      metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
      inserted_at timestamp(6) without time zone NOT NULL,
      updated_at timestamp(6) without time zone NOT NULL,
      CONSTRAINT gao_note_assets_pkey PRIMARY KEY (id),
      CONSTRAINT gao_note_assets_note_id_fkey
        FOREIGN KEY (note_id) REFERENCES public.gao_notes(id) ON DELETE CASCADE,
      CONSTRAINT gao_note_assets_storage_file_id_fkey
        FOREIGN KEY (storage_file_id)
        REFERENCES public.storage_files(id)
        ON DELETE CASCADE
    );

    CREATE INDEX gao_note_assets_note_id_index
      ON public.gao_note_assets (note_id);

    CREATE INDEX gao_note_assets_storage_file_id_index
      ON public.gao_note_assets (storage_file_id);

    CREATE UNIQUE INDEX gao_note_assets_note_id_storage_file_id_index
      ON public.gao_note_assets (note_id, storage_file_id);
    """
  end

  # Mirrors the current 20260612000005 CreateGaoNoteAttachments migration.
  # The old-name variant models an already-renamed development table whose
  # PostgreSQL identifiers still retain the Asset prefix.
  defp expanded_asset_table_sql do
    persistence_table_sql("gao_note_assets", "gao_note_assets")
  end

  defp attachment_table_sql(:attachment) do
    persistence_table_sql("gao_note_attachments", "gao_note_attachments")
  end

  defp attachment_table_sql(:asset) do
    persistence_table_sql("gao_note_attachments", "gao_note_assets")
  end

  defp persistence_table_sql(table, identifier_prefix) do
    """
    CREATE TABLE public.#{table} (
      id uuid NOT NULL,
      note_id uuid NOT NULL,
      storage_file_id uuid NOT NULL,
      role varchar(255) DEFAULT 'attachment' NOT NULL,
      description text DEFAULT '' NOT NULL,
      path text,
      caption text,
      alt_text text,
      position integer DEFAULT 0 NOT NULL,
      metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
      inserted_at timestamp(6) without time zone NOT NULL,
      updated_at timestamp(6) without time zone NOT NULL,
      CONSTRAINT #{identifier_prefix}_pkey PRIMARY KEY (id),
      CONSTRAINT #{identifier_prefix}_note_id_fkey
        FOREIGN KEY (note_id) REFERENCES public.gao_notes(id) ON DELETE CASCADE,
      CONSTRAINT #{identifier_prefix}_storage_file_id_fkey
        FOREIGN KEY (storage_file_id)
        REFERENCES public.storage_files(id)
        ON DELETE CASCADE
    );

    CREATE INDEX #{identifier_prefix}_note_id_index
      ON public.#{table} (note_id);

    CREATE INDEX #{identifier_prefix}_storage_file_id_index
      ON public.#{table} (storage_file_id);

    CREATE UNIQUE INDEX #{identifier_prefix}_note_id_storage_file_id_index
      ON public.#{table} (note_id, storage_file_id);

    CREATE UNIQUE INDEX #{identifier_prefix}_note_id_path_index
      ON public.#{table} (note_id, path)
      WHERE path IS NOT NULL;
    """
  end

  defp legacy_row_sql(table, attributes) do
    attributes =
      Map.merge(
        %{
          role: "attachment",
          caption: nil,
          alt_text: nil,
          position: 0,
          metadata: "{}"
        },
        attributes
      )

    """
    INSERT INTO public.#{table} (
      id,
      note_id,
      storage_file_id,
      role,
      caption,
      alt_text,
      position,
      metadata,
      inserted_at,
      updated_at
    )
    VALUES (
      #{literal(attributes.id)},
      #{literal(attributes.note_id)},
      #{literal(attributes.storage_file_id)},
      #{literal(attributes.role)},
      #{literal(attributes.caption)},
      #{literal(attributes.alt_text)},
      #{attributes.position},
      #{literal(attributes.metadata)}::jsonb,
      now(),
      now()
    );
    """
  end

  defp row_sql(table, attributes) do
    attributes =
      Map.merge(
        %{
          role: "attachment",
          description: "",
          path: nil,
          caption: nil,
          alt_text: nil,
          position: 0,
          metadata: "{}"
        },
        attributes
      )

    """
    INSERT INTO public.#{table} (
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
    VALUES (
      #{literal(attributes.id)},
      #{literal(attributes.note_id)},
      #{literal(attributes.storage_file_id)},
      #{literal(attributes.role)},
      #{literal(attributes.description)},
      #{literal(attributes.path)},
      #{literal(attributes.caption)},
      #{literal(attributes.alt_text)},
      #{attributes.position},
      #{literal(attributes.metadata)}::jsonb,
      now(),
      now()
    );
    """
  end

  defp literal(nil), do: "NULL"

  defp literal(value) do
    "'#{String.replace(value, "'", "''")}'"
  end

  defp table_fingerprint(database, table) do
    query(
      database,
      """
      SELECT md5(
        COALESCE(
          string_agg(row_to_json(table_row)::text, '|' ORDER BY table_row.id),
          ''
        )
      )
      FROM public.#{table} AS table_row
      """
    )
  end

  defp migrate!(database) do
    execute_sql!(database, @migration.up_sql())
  end

  defp query(database, sql) do
    database
    |> execute_sql!(sql)
    |> String.trim()
  end

  defp execute_sql!(database, sql) do
    case execute_sql(database, sql) do
      {output, 0} ->
        output

      {output, status} ->
        flunk("psql exited with status #{status}:\n#{output}")
    end
  end

  defp execute_sql(database, sql) do
    System.cmd(
      "psql",
      [
        "-X",
        "--set",
        "ON_ERROR_STOP=1",
        "--no-align",
        "--tuples-only",
        "--dbname",
        database,
        "--command",
        sql
      ],
      stderr_to_stdout: true
    )
  end

  defp command!(command, arguments) do
    case System.cmd(command, arguments, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        flunk("#{command} exited with status #{status}:\n#{output}")
    end
  end
end
