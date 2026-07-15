defmodule GSMLG.Repo.Migrations.DropGaoNoteCreatorFields do
  use Ecto.Migration

  def up do
    execute("DROP INDEX IF EXISTS public.gao_notes_creator_index")
    execute("DROP INDEX IF EXISTS public.gao_notes_creator_id_index")
    execute("ALTER TABLE public.gao_notes DROP COLUMN IF EXISTS creator")
    execute("ALTER TABLE public.gao_notes DROP COLUMN IF EXISTS creator_id")
  end

  def down do
    raise Ecto.MigrationError,
          "cannot restore GaoNote Creator fields because their data was intentionally discarded"
  end
end
