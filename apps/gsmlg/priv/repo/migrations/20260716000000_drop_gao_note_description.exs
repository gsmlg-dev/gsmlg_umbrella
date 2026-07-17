defmodule GSMLG.Repo.Migrations.DropGaoNoteDescription do
  use Ecto.Migration

  def up do
    alter table(:gao_notes) do
      remove_if_exists :description, :text
    end
  end

  def down do
    :ok
  end
end
