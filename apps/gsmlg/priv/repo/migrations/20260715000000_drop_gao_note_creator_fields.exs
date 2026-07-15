defmodule GSMLG.Repo.Migrations.DropGaoNoteCreatorFields do
  use Ecto.Migration

  @up_sql """
  DROP INDEX IF EXISTS public.gao_notes_creator_index;
  DROP INDEX IF EXISTS public.gao_notes_creator_id_index;

  ALTER TABLE public.gao_notes
    DROP COLUMN IF EXISTS creator,
    DROP COLUMN IF EXISTS creator_id;
  """

  def up do
    execute(@up_sql)
  end

  def down do
    raise Ecto.MigrationError,
          "cannot restore GaoNote Creator fields because their data was intentionally discarded"
  end

  def up_sql, do: @up_sql
end
