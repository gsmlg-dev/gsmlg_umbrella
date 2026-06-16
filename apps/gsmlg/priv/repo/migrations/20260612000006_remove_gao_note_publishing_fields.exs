defmodule GSMLG.Repo.Migrations.RemoveGaoNotePublishingFields do
  use Ecto.Migration

  def up do
    drop_if_exists unique_index(:gao_notes, [:slug])
    drop_if_exists index(:gao_notes, [:status])
    drop_if_exists index(:gao_notes, [:visibility])
    drop_if_exists index(:gao_notes, [:published_at])

    alter table(:gao_notes) do
      remove_if_exists :slug, :string
      remove_if_exists :summary, :text
      remove_if_exists :status, :string
      remove_if_exists :visibility, :string
      remove_if_exists :published_at, :utc_datetime_usec
    end
  end

  def down do
    :ok
  end
end
