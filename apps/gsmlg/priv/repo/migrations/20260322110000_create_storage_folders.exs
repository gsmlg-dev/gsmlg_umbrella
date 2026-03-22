defmodule GSMLG.Repo.Migrations.CreateStorageFolders do
  use Ecto.Migration

  def change do
    create table(:storage_folders, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant, :string, null: false
      add :type, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:storage_folders, [:tenant, :type],
             name: :storage_folders_tenant_type_index
           )

    create index(:storage_folders, [:tenant])
  end
end
