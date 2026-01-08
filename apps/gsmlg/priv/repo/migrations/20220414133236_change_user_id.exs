defmodule GSMLG.Repo.Migrations.ChangeUserId do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # PostgreSQL bytea doesn't support size modifier, use string type for fixed-length IDs
      modify(:id, :string, size: 40)
    end

    create(unique_index(:users, [:username]))
    create(unique_index(:users, [:email]))
  end
end
