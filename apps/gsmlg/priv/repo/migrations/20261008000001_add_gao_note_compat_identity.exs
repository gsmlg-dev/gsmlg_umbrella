defmodule GSMLG.Repo.Migrations.AddGaoNoteCompatIdentity do
  use Ecto.Migration

  def up do
    alter table(:gao_note_attachments) do
      add :api_id, :text
    end

    execute "UPDATE gao_note_attachments SET api_id = id"

    alter table(:gao_note_attachments) do
      modify :api_id, :text, null: false
    end

    create unique_index(:gao_note_attachments, [:note_id, :api_id])

    drop_if_exists index(:gao_note_label_settings, ["lower(name)"],
                     name: :gao_note_label_settings_lower_name_index
                   )

    create unique_index(:gao_note_label_settings, [:name])
  end

  def down do
    drop index(:gao_note_label_settings, [:name])

    create unique_index(:gao_note_label_settings, ["lower(name)"],
             name: :gao_note_label_settings_lower_name_index
           )

    drop index(:gao_note_attachments, [:note_id, :api_id])

    alter table(:gao_note_attachments) do
      remove :api_id
    end
  end
end
