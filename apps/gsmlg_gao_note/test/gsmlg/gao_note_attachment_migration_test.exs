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

  setup do
    database =
      "gao_note_attachment_migration_#{System.unique_integer([:positive, :monotonic])}"

    command!("createdb", [database])

    on_exit(fn ->
      System.cmd("dropdb", ["--if-exists", database], stderr_to_stdout: true)
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

  test "assets-only state preserves legacy rows", %{database: database} do
    execute_sql!(database, asset_table_sql())

    execute_sql!(
      database,
      row_sql("gao_note_assets", %{
        id: @row_1,
        note_id: @note_1,
        storage_file_id: @storage_1,
        description: "legacy asset",
        path: "./legacy.txt"
      })
    )

    migrate!(database)

    assert query(
             database,
             "SELECT description || '|' || path FROM gao_note_attachments WHERE id = '#{@row_1}'"
           ) == "legacy asset|./legacy.txt"

    assert_final_state(database)
  end

  test "attachments-only state normalizes names and converts legacy storage types", %{
    database: database
  } do
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

    assert query(
             database,
             "SELECT type FROM storage_files WHERE id = '#{@storage_1}'"
           ) == "attachment"

    assert_final_state(database)
  end

  test "coexistence inserts every non-conflicting asset", %{database: database} do
    execute_sql!(database, asset_table_sql())
    execute_sql!(database, attachment_table_sql(:attachment))

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
    execute_sql!(database, asset_table_sql())
    execute_sql!(database, attachment_table_sql(:attachment))

    execute_sql!(
      database,
      row_sql("gao_note_assets", %{
        id: @row_1,
        note_id: @note_1,
        storage_file_id: @storage_1,
        role: "legacy-role",
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
        role: "attachment-role",
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
             "attachment-role|legacy description|./legacy.txt|legacy caption|" <>
               "attachment alt text|9|yes|yes|attachment"

    assert query(database, "SELECT count(*) FROM gao_note_attachments") == "1"
    assert_final_state(database)
  end

  test "same ID with divergent note/storage identity rolls back", %{database: database} do
    prepare_conflict!(
      database,
      row_sql("gao_note_assets", %{
        id: @row_1,
        note_id: @note_1,
        storage_file_id: @storage_1,
        path: "./asset.txt"
      }),
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
    prepare_conflict!(
      database,
      row_sql("gao_note_assets", %{
        id: @row_1,
        note_id: @note_1,
        storage_file_id: @storage_1,
        path: "./asset.txt"
      }),
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
    prepare_conflict!(
      database,
      row_sql("gao_note_assets", %{
        id: @row_1,
        note_id: @note_1,
        storage_file_id: @storage_1,
        path: "./same.txt"
      }),
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
    execute_sql!(database, asset_table_sql())
    execute_sql!(database, attachment_table_sql(:attachment))

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

  defp prepare_conflict!(database, asset_sql, attachment_sql) do
    execute_sql!(database, asset_table_sql())
    execute_sql!(database, attachment_table_sql(:attachment))
    execute_sql!(database, asset_sql)
    execute_sql!(database, attachment_sql)
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
             "gao_note_attachments_note_id_path_index," <>
               "gao_note_attachments_note_id_storage_file_id_index," <>
               "gao_note_attachments_pkey"

    assert query(
             database,
             """
             SELECT bool_and(indexdef LIKE 'CREATE UNIQUE INDEX%')
             FROM pg_indexes
             WHERE schemaname = 'public'
               AND tablename = 'gao_note_attachments'
             """
           ) == "t"

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

  defp asset_table_sql, do: persistence_table_sql("gao_note_assets", "gao_note_assets")

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
      role text,
      description text DEFAULT '' NOT NULL,
      path text,
      caption text,
      alt_text text,
      position integer,
      metadata jsonb DEFAULT '{}'::jsonb,
      inserted_at timestamp without time zone DEFAULT now() NOT NULL,
      updated_at timestamp without time zone DEFAULT now() NOT NULL,
      CONSTRAINT #{identifier_prefix}_pkey PRIMARY KEY (id),
      CONSTRAINT #{identifier_prefix}_note_id_fkey
        FOREIGN KEY (note_id) REFERENCES public.gao_notes(id),
      CONSTRAINT #{identifier_prefix}_storage_file_id_fkey
        FOREIGN KEY (storage_file_id) REFERENCES public.storage_files(id)
    );

    CREATE UNIQUE INDEX #{identifier_prefix}_note_id_storage_file_id_index
      ON public.#{table} (note_id, storage_file_id);

    CREATE UNIQUE INDEX #{identifier_prefix}_note_id_path_index
      ON public.#{table} (note_id, path);
    """
  end

  defp row_sql(table, attributes) do
    attributes =
      Map.merge(
        %{
          role: "file",
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
      metadata
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
      #{literal(attributes.metadata)}::jsonb
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
