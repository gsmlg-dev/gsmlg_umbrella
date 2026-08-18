defmodule GSMLG.GaoNote.CategorySetting do
  use Ecto.Schema
  import Ecto.Changeset

  alias GSMLG.GaoNote.LabelSetting

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "gao_note_category_settings" do
    belongs_to(:label_setting, LabelSetting)
    field(:value, :string)
    field(:position, :integer)

    timestamps()
  end

  def changeset(category_setting, attrs) do
    category_setting
    |> cast(attrs, [:label_setting_id, :value, :position])
    |> validate_required([:label_setting_id, :position])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:label_setting_id,
      name: :gao_note_category_settings_label_setting_id_fkey
    )
    |> unique_constraint(:position, name: :gao_note_category_settings_position_index)
    |> unique_constraint(:label_setting_id,
      name: :gao_note_category_settings_key_wide_index
    )
    |> unique_constraint([:label_setting_id, :value],
      name: :gao_note_category_settings_exact_selector_index
    )
    |> check_constraint(:position, name: :category_position_non_negative)
  end
end
