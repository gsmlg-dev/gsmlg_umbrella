defmodule GSMLG.GaoNote.Log do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false]

  schema "gao_note_logs" do
    field(:action, :string)
    field(:entity_type, :string)
    field(:entity_id, :binary_id)
    field(:note_id, :binary_id)
    field(:actor_id, :string)
    field(:source, :string, default: "admin")
    field(:details, :map, default: %{})

    timestamps()
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:action, :entity_type, :entity_id, :note_id, :actor_id, :source, :details])
    |> validate_required([:action, :entity_type, :source])
  end
end
