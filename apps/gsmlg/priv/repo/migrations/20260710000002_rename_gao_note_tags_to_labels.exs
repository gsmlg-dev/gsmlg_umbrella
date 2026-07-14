defmodule GSMLG.Repo.Migrations.RenameGaoNoteTagsToLabels do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF to_regclass('public.gao_note_label_settings') IS NULL
         AND to_regclass('public.gao_note_tags') IS NOT NULL THEN
        ALTER TABLE gao_note_tags RENAME TO gao_note_label_settings;
      END IF;

      IF to_regclass('public.gao_note_labels') IS NULL
         AND to_regclass('public.gao_note_taggings') IS NOT NULL THEN
        ALTER TABLE gao_note_taggings RENAME TO gao_note_labels;
      END IF;

      IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'gao_note_labels'
          AND column_name = 'tag_id'
      ) AND NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'gao_note_labels'
          AND column_name = 'label_setting_id'
      ) THEN
        ALTER TABLE gao_note_labels RENAME COLUMN tag_id TO label_setting_id;
      END IF;
    END $$;
    """)

    alter table(:gao_note_label_settings) do
      add_if_not_exists :description, :text, null: false, default: ""
      add_if_not_exists :value_type, :string, null: false, default: "text"
    end

    alter table(:gao_note_labels) do
      add_if_not_exists :value, :text
      add_if_not_exists :status, :string, null: false, default: "valid"
      add_if_not_exists :errors, {:array, :string}, null: false, default: []
    end

    create_if_not_exists unique_index(:gao_note_label_settings, ["lower(name)"],
                           name: :gao_note_label_settings_lower_name_index
                         )

    create_if_not_exists index(:gao_note_label_settings, [:value_type])
    create_if_not_exists unique_index(:gao_note_labels, [:note_id, :label_setting_id])
    create_if_not_exists index(:gao_note_labels, [:label_setting_id])
    create_if_not_exists index(:gao_note_labels, [:status])

    alter table(:gao_note_attachments) do
      add_if_not_exists :description, :text, null: false, default: ""
      add_if_not_exists :path, :text
    end

    create_if_not_exists unique_index(:gao_note_attachments, [:note_id, :path],
                           where: "path IS NOT NULL"
                         )
  end

  def down do
    :ok
  end
end
