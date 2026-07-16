defmodule GSMLG.Repo.Migrations.AddDeletedAtToGaoNotes do
  use Ecto.Migration

  def change do
    alter table(:gao_notes) do
      add_if_not_exists :deleted_at, :utc_datetime_usec
    end

    create_if_not_exists index(:gao_notes, [:deleted_at])
  end
end
