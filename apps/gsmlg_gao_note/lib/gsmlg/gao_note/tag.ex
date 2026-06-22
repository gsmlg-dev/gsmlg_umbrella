defmodule GSMLG.GaoNote.Tag do
  use Ecto.Schema
  import Ecto.Changeset

  alias GSMLG.GaoNote.{Note, Tagging}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]
  @slug_format ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/

  schema "gao_note_tags" do
    field(:name, :string)
    field(:slug, :string)
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
    |> cast(attrs, [:name, :slug, :color, :metadata])
    |> normalize_name()
    |> ensure_slug()
    |> validate_required([:name, :slug])
    |> validate_format(:slug, @slug_format)
    |> unique_constraint(:slug)
    |> unique_constraint(:name, name: :gao_note_tags_lower_name_index)
  end

  def normalize_display_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  def normalize_display_name(name), do: name

  def slugify(value) when is_binary(value) do
    value = String.trim(value)

    folded =
      value
      |> String.downcase()
      |> String.normalize(:nfd)
      |> String.replace(~r/\p{M}/u, "")

    stem =
      folded
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")

    cond do
      stem == "" and contains_non_ascii?(folded) ->
        "tag-#{slug_hash(value)}"

      stem != "" and contains_non_ascii?(folded) ->
        "#{stem}-#{slug_hash(value)}"

      true ->
        stem
    end
  end

  def slugify(_value), do: ""

  defp contains_non_ascii?(value), do: String.match?(value, ~r/[^\x00-\x7F]/u)

  defp slug_hash(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 10)
  end

  defp normalize_name(changeset) do
    case get_change(changeset, :name) do
      name when is_binary(name) -> put_change(changeset, :name, normalize_display_name(name))
      _ -> changeset
    end
  end

  defp ensure_slug(changeset) do
    slug = get_change(changeset, :slug) || get_field(changeset, :slug)

    cond do
      is_binary(slug) and String.trim(slug) != "" ->
        put_change(changeset, :slug, slugify(slug))

      name = get_field(changeset, :name) ->
        put_change(changeset, :slug, slugify(name))

      true ->
        changeset
    end
  end
end
