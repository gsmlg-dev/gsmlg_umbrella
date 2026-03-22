defmodule GSMLG.Storage.StorageFolder do
  @moduledoc """
  Represents an explicit storage folder (tenant + optional type).
  Allows empty folders to persist in the file browser tree independent
  of whether any files exist under that path.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "storage_folders" do
    field :tenant, :string
    field :type, :string

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
