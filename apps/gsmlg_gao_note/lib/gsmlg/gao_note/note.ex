defmodule GSMLG.GaoNote.Note do
  use Ecto.Schema
  import Ecto.Changeset

  alias GSMLG.GaoNote.{Asset, Reference, Tag, Tagging}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  schema "gao_notes" do
    field(:title, :string)
    field(:description, :string)
    field(:content, :string)
    field(:creator, :string)

    has_many(:references, Reference, foreign_key: :note_id)
    has_many(:assets, Asset, foreign_key: :note_id)

    many_to_many(:tags, Tag,
      join_through: Tagging,
      join_keys: [note_id: :id, tag_id: :id],
      on_replace: :delete
    )

    timestamps()
  end

  def changeset(note, attrs) do
    note
    |> cast(attrs, [:title, :description, :content, :creator], empty_values: [])
    |> put_default_description()
    |> put_default_creator()
    |> validate_required([:title, :content])
  end

  def create_changeset(note, attrs) do
    note
    |> cast(attrs, [:title, :description, :content, :creator], empty_values: [])
    |> put_default_description()
    |> put_default_creator()
    |> validate_required([:title, :content])
  end

  defp put_default_description(changeset) do
    case get_field(changeset, :description) do
      nil -> put_change(changeset, :description, "")
      _description -> changeset
    end
  end

  defp put_default_creator(changeset) do
    case get_field(changeset, :creator) do
      nil -> put_change(changeset, :creator, "")
      _creator -> changeset
    end
  end
end
