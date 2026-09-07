defmodule GSMLG.Browser.Node do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]
  @statuses ~w(online degraded offline disabled)

  schema "browser_nodes" do
    field(:online?, :boolean, virtual: true, default: false)
    field(:commander_id, :string)
    field(:enabled, :boolean, default: true)
    field(:default_backend, :string)
    field(:status, :string, default: "offline")
    field(:capabilities, {:array, :map}, default: [])
    field(:limits, :map, default: %{})
    field(:last_seen_at, :utc_datetime_usec)
    field(:last_error, :map)
    field(:metadata, :map, default: %{})

    timestamps()
  end

  def changeset(node, attrs) do
    node
    |> cast(attrs, [
      :commander_id,
      :enabled,
      :default_backend,
      :status,
      :capabilities,
      :limits,
      :last_seen_at,
      :last_error,
      :metadata
    ])
    |> validate_required([:commander_id, :default_backend, :status])
    |> validate_length(:commander_id, min: 1, max: 255)
    |> validate_length(:default_backend, min: 1, max: 255)
    |> validate_inclusion(:status, @statuses)
    |> GSMLG.Browser.Sanitizer.validate_changeset(
      capabilities: 32_768,
      limits: 16_384,
      last_error: 4_096,
      metadata: 16_384
    )
    |> unique_constraint(:commander_id)
  end
end
