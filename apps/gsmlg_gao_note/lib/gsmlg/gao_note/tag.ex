defmodule GSMLG.GaoNote.Tag do
  use Ecto.Schema
  import Ecto.Changeset

  alias GSMLG.GaoNote.{Note, Tagging}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "gao_note_tags" do
    field(:name, :string)
    field(:color, :string)
    field(:metadata, :map, default: %{})

    many_to_many(:notes, Note,
      join_through: Tagging,
      join_keys: [tag_id: :id, note_id: :id]
    )

    timestamps()
  end

  def changeset(tag, attrs) do
    tag
    |> cast(attrs, [:name, :color, :metadata])
    |> normalize_name()
    |> validate_required([:name])
    |> unique_constraint(:name, name: :gao_note_tags_lower_name_index)
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
end
