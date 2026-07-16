defmodule GSMLG.GaoNote.Label do
  use Ecto.Schema
  import Ecto.Changeset

  alias GSMLG.GaoNote.{Note, LabelSetting}

  @primary_key false
  @foreign_key_type :binary_id

  schema "gao_note_labels" do
    belongs_to(:note, Note)
    belongs_to(:label_setting, LabelSetting)
    field(:value, :string)
    field(:status, :string, default: "valid")
    field(:errors, {:array, :string}, default: [])
  end

  def changeset(label, attrs) do
    label
    |> cast(attrs, [:note_id, :label_setting_id, :value, :status, :errors])
    |> validate_required([:note_id, :label_setting_id])
    |> validate_inclusion(:status, ["valid", "invalid"],
      message: "status must be valid or invalid"
    )
    |> unique_constraint([:note_id, :label_setting_id])
  end
end
