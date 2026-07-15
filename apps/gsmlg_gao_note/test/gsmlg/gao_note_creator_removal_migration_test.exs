defmodule GSMLG.GaoNote.CreatorRemovalMigrationTest do
  use ExUnit.Case, async: false

  @migration GSMLG.Repo.Migrations.DropGaoNoteCreatorFields
  @repo_root Path.expand("../../../..", __DIR__)
  @migration_file Path.join(
                    @repo_root,
                    "apps/gsmlg/priv/repo/migrations/20260715000000_drop_gao_note_creator_fields.exs"
                  )

  unless Code.ensure_loaded?(@migration) do
    Code.compile_file(@migration_file)
  end

  setup do
    database =
      "gao_note_creator_removal_#{System.unique_integer([:positive, :monotonic])}"

    command!("createdb", [database])

    on_exit(fn ->
      case System.cmd("dropdb", ["--if-exists", database], stderr_to_stdout: true) do
        {_output, 0} ->
          :ok

        {output, status} ->
          raise "dropdb cleanup failed for #{database} with status #{status}:\n#{output}"
      end
    end)

    %{database: database}
  end

  test "up removes either, both, or neither legacy column and index", %{database: database} do
    states = [
      {[], []},
      {["creator"], ["creator"]},
      {["creator_id"], ["creator_id"]},
      {["creator", "creator_id"], ["creator", "creator_id"]},
      {["creator", "creator_id"], []}
    ]

    for {columns, indexed_columns} <- states do
      reset_schema!(database, columns, indexed_columns)
      migrate!(database)
      migrate!(database)

      assert query(
               database,
               """
               SELECT count(*)
               FROM information_schema.columns
               WHERE table_schema = 'public'
                 AND table_name = 'gao_notes'
                 AND column_name IN ('creator', 'creator_id')
               """
             ) == "0"

      assert query(
               database,
               """
               SELECT count(*)
               FROM pg_indexes
               WHERE schemaname = 'public'
                 AND tablename = 'gao_notes'
                 AND indexname IN ('gao_notes_creator_index', 'gao_notes_creator_id_index')
               """
             ) == "0"

      assert query(database, "SELECT title FROM public.gao_notes") == "preserved"
    end
  end

  test "down is explicitly irreversible" do
    assert_raise Ecto.MigrationError, ~r/intentionally discarded/, fn ->
      @migration.down()
    end
  end

  defp reset_schema!(database, columns, indexed_columns) do
    execute_sql!(
      database,
      """
      DROP TABLE IF EXISTS public.gao_notes;

      CREATE TABLE public.gao_notes (
        id uuid PRIMARY KEY,
        title varchar(255) NOT NULL
      );

      INSERT INTO public.gao_notes (id, title)
      VALUES ('10000000-0000-0000-0000-000000000001', 'preserved');
      """
    )

    Enum.each(columns, fn column ->
      execute_sql!(database, "ALTER TABLE public.gao_notes ADD COLUMN #{column} varchar(255)")
    end)

    Enum.each(indexed_columns, fn column ->
      execute_sql!(
        database,
        "CREATE INDEX gao_notes_#{column}_index ON public.gao_notes (#{column})"
      )
    end)
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
    case System.cmd(
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
         ) do
      {output, 0} -> output
      {output, status} -> flunk("psql exited with status #{status}:\n#{output}")
    end
  end

  defp command!(command, arguments) do
    case System.cmd(command, arguments, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("#{command} exited with status #{status}:\n#{output}")
    end
  end
end
