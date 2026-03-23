defmodule GSMLG.Repo.Migrations.CreateApiProviders do
  use Ecto.Migration

  def change do
    create table(:api_providers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider, :string, null: false
      add :name, :string, null: false
      add :auth_type, :string, null: false, default: "token"
      add :credentials, :text, null: false, default: ""
      add :metadata, :map, null: false, default: %{}
      add :active, :boolean, null: false, default: true

      timestamps()
    end

    create unique_index(:api_providers, [:provider, :name])
    create index(:api_providers, [:provider])
    create index(:api_providers, [:active])
  end
end
