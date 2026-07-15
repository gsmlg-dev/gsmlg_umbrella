defmodule GSMLG.GaoNote.Note do
  use Ecto.Schema
  import Ecto.Changeset

  alias GSMLG.GaoNote.{Attachment, Label}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  schema "gao_notes" do
    field(:title, :string)
    field(:description, :string)
    field(:content, :string)
    field(:deleted_at, :utc_datetime_usec)

    has_many(:attachments, Attachment, foreign_key: :note_id)
    has_many(:labels, Label, foreign_key: :note_id)

    timestamps()
  end

  def changeset(note, attrs) do
    note
    |> cast(attrs, [:title, :description, :content])
    |> put_default_description()
    |> validate_required([:title, :content])
  end

  def create_changeset(note, attrs) do
    note
    |> cast(attrs, [:title, :description, :content])
    |> put_default_description()
    |> validate_required([:title, :content])
  end

  defp put_default_description(changeset) do
    case get_field(changeset, :description) do
      nil -> put_change(changeset, :description, "")
      _description -> changeset
    end
  end
end
