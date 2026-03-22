defmodule GSMLG.Storage.StorageConfig do
  @moduledoc """
  Singleton Ecto schema for S3 storage configuration.
  Always id=1. Use GSMLG.Storage.get_config/0 and update_config/2 to access.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "storage_config" do
    field :s3_bucket, :string
    field :s3_endpoint, :string
    field :s3_region, :string
    field :s3_access_key_id, :string
    field :s3_secret_access_key, :string
    field :max_file_size, :integer
    field :cleanup_interval, :integer
    field :retention_window, :integer

    timestamps()
  end

  @fields ~w(s3_bucket s3_endpoint s3_region s3_access_key_id s3_secret_access_key
             max_file_size cleanup_interval retention_window)a

  def changeset(config, attrs) do
    config
    |> cast(attrs, @fields)
    |> validate_number(:max_file_size, greater_than: 0)
    |> validate_number(:cleanup_interval, greater_than: 0)
    |> validate_number(:retention_window, greater_than: 0)
  end
end
