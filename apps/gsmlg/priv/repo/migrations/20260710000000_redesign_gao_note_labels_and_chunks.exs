defmodule GSMLG.Repo.Migrations.RedesignGaoNoteLabelsAndChunks do
  use Ecto.Migration

  def up do
    alter table(:gao_notes) do
      remove_if_exists :content_chunks, {:array, :map}
    end
  end

  def down do
    :ok
  end
end
