defmodule GSMLG.Storage.StorageFolder do
  @moduledoc """
  Validates legacy folder names for S3 directory markers.
  The legacy table remains available for the explicit one-time export.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "storage_folders" do
    field(:tenant, :string)
    field(:type, :string)

    timestamps()
  end

  def changeset(folder, attrs) do
    folder
    |> cast(attrs, [:tenant, :type])
    |> validate_required([:tenant])
    |> validate_format(:tenant, ~r/^[a-z0-9_\-]+$/i, message: "only letters, numbers, - and _")
    |> validate_format(:type, ~r/^[a-z0-9_\-]+$/i, message: "only letters, numbers, - and _")
    |> unique_constraint([:tenant, :type], name: :storage_folders_tenant_type_index)
  end
end
