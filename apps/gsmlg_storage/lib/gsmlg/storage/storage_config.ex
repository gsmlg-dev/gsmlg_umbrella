defmodule GSMLG.Storage.StorageConfig do
  @moduledoc """
  Singleton Ecto schema for S3 storage configuration.
  Always id=1. Use GSMLG.Storage.get_config/0 and update_config/2 to access.

  NOTE: s3_access_key_id and s3_secret_access_key are stored in plaintext.
  Ensure the database and backups are access-controlled appropriately.
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
    field :s3_secret_access_key, :string, redact: true
    field :max_file_size, :integer
    field :cleanup_interval, :integer
    field :retention_window, :integer

    timestamps()
  end

  @non_credential_fields ~w(s3_bucket s3_endpoint s3_region max_file_size cleanup_interval retention_window)a
  @credential_fields ~w(s3_access_key_id s3_secret_access_key)a

  def changeset(config, attrs) do
    config
    |> cast(attrs, @non_credential_fields ++ @credential_fields)
    |> reject_blank_credentials()
    |> validate_number(:max_file_size, greater_than: 0)
    |> validate_number(:cleanup_interval, greater_than: 0)
    |> validate_number(:retention_window, greater_than: 0)
  end

  # Prevent empty string submissions from clearing stored credentials.
  # An empty string in the form means "leave unchanged", not "clear the value".
  defp reject_blank_credentials(changeset) do
    Enum.reduce(@credential_fields, changeset, fn field, cs ->
      case get_change(cs, field) do
        val when val == "" or val == nil -> delete_change(cs, field)
        _ -> cs
      end
    end)
  end
end
