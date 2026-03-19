defmodule GSMLG.Repo.Migrations.CreateStorageFiles do
  use Ecto.Migration

  def change do
    create table(:storage_files, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant, :string, null: false
      add :type, :string, null: false
      add :filename, :string, null: false
      add :s3_key, :string, null: false
      add :content_type, :string, null: false
      add :size, :bigint, null: false
      add :checksum, :string
      add :metadata, :map, default: %{}
      add :variants, :map, default: %{}
      add :status, :string, null: false, default: "active"
      add :uploaded_by, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:storage_files, [:s3_key])
    create index(:storage_files, [:tenant, :type])
    create index(:storage_files, [:tenant, :status])
  end
end
