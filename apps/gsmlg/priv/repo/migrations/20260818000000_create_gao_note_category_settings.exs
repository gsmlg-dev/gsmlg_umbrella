defmodule GSMLG.Repo.Migrations.CreateGaoNoteCategorySettings do
  use Ecto.Migration

  def change do
    create table(:gao_note_category_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :label_setting_id,
          references(:gao_note_label_settings,
            type: :binary_id,
            on_delete: :restrict,
            name: :gao_note_category_settings_label_setting_id_fkey
          ),
          null: false

      add :value, :text
      add :position, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gao_note_category_settings, [:position],
             name: :gao_note_category_settings_position_index
           )

    create unique_index(:gao_note_category_settings, [:label_setting_id],
             where: "value IS NULL",
             name: :gao_note_category_settings_key_wide_index
           )

    create unique_index(:gao_note_category_settings, [:label_setting_id, :value],
             where: "value IS NOT NULL",
             name: :gao_note_category_settings_exact_selector_index
           )

    create index(:gao_note_category_settings, [:label_setting_id],
             name: :gao_note_category_settings_label_setting_id_index
           )

    create constraint(:gao_note_category_settings, :category_position_non_negative,
             check: "position >= 0"
           )
  end
end
