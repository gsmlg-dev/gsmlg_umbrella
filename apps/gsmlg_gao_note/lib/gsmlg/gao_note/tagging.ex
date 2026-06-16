defmodule GSMLG.GaoNote.Tagging do
  use Ecto.Schema
  import Ecto.Changeset

  alias GSMLG.GaoNote.{Note, Tag}

  @primary_key false
  @foreign_key_type :binary_id

  schema "gao_note_taggings" do
    belongs_to(:note, Note)
    belongs_to(:tag, Tag)
  end

  def changeset(tagging, attrs) do
    tagging
    |> cast(attrs, [:note_id, :tag_id])
    |> validate_required([:note_id, :tag_id])
    |> unique_constraint([:note_id, :tag_id])
  end
end
