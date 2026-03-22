defmodule GSMLG.Repo.Migrations.CreateStorageConfig do
  use Ecto.Migration

  def change do
    create table(:storage_config, primary_key: false) do
      add :id, :integer, primary_key: true, default: 1
      add :s3_bucket, :string
      add :s3_endpoint, :string
      add :s3_region, :string
      add :s3_access_key_id, :string
      add :s3_secret_access_key, :string
      add :max_file_size, :bigint
      add :cleanup_interval, :integer
      add :retention_window, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:storage_config, :single_row, check: "id = 1")
  end
end
