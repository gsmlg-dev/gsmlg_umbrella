defmodule GSMLG.GaoNote.LabelSetting do
  use Ecto.Schema
  import Ecto.Changeset

  alias GSMLG.GaoNote.{CategorySetting, Label}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]
  @value_types ~w(text number version date date-time time year year-month year-season)

  schema "gao_note_label_settings" do
    field(:name, :string)
    field(:color, :string)
    field(:description, :string, default: "")
    field(:value_type, :string, default: "text")
    field(:metadata, :map, default: %{})
    field(:note_count, :integer, virtual: true, default: 0)
    field(:category_count, :integer, virtual: true, default: 0)

    has_many(:labels, Label, foreign_key: :label_setting_id)
    has_many(:category_settings, CategorySetting, foreign_key: :label_setting_id)

    timestamps()
  end

  def changeset(label_setting, attrs) do
    label_setting
    |> cast(attrs, [:name, :color, :description, :value_type, :metadata])
    |> normalize_name()
    |> put_default_description()
    |> put_default_value_type()
    |> normalize_value_type()
    |> validate_required([:name])
    |> validate_inclusion(:value_type, @value_types, message: "unsupported value type")
    |> unique_constraint(:name, name: :gao_note_label_settings_lower_name_index)
  end

  def normalize_display_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  def normalize_display_name(name), do: name

  def normalized_key(name) when is_binary(name),
    do: name |> normalize_display_name() |> String.downcase()

  def normalized_key(_name), do: ""

  defp normalize_name(changeset) do
    case get_change(changeset, :name) do
      name when is_binary(name) -> put_change(changeset, :name, normalize_display_name(name))
      _ -> changeset
    end
  end

  defp put_default_description(changeset) do
    case get_field(changeset, :description) do
      nil -> put_change(changeset, :description, "")
      _description -> changeset
    end
  end

  defp put_default_value_type(changeset) do
    case get_field(changeset, :value_type) do
      nil -> put_change(changeset, :value_type, "text")
      _value_type -> changeset
    end
  end

  defp normalize_value_type(changeset) do
    case get_change(changeset, :value_type) do
      nil ->
        changeset

      value_type when is_binary(value_type) ->
        put_change(changeset, :value_type, value_type |> String.trim() |> String.downcase())

      _ ->
        changeset
    end
  end

  def value_types, do: @value_types
end
