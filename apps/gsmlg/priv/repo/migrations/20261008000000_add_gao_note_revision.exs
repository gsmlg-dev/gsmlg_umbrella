defmodule GSMLG.Repo.Migrations.AddGaoNoteRevision do
  use Ecto.Migration

  def change do
    alter table(:gao_notes) do
      add :revision, :bigint, null: false, default: 1
    end

    create constraint(:gao_notes, :gao_notes_positive_revision, check: "revision > 0")
  end
end
