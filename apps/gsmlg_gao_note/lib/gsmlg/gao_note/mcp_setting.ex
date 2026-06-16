defmodule GSMLG.GaoNote.MCPSetting do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "gao_note_mcp_settings" do
    field(:api_key_hash, :string)
    field(:api_key_hint, :string)
    field(:actor_id, :string)

    timestamps()
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:id, :api_key_hash, :api_key_hint, :actor_id])
    |> validate_required([:id, :api_key_hash, :api_key_hint, :actor_id])
    |> foreign_key_constraint(:actor_id)
  end
end
