defmodule GSMLG.Repo.Migrations.ChangeUserId do
  use Ecto.Migration

  def change do
    alter table(:users) do
      modify(:id, :binary, size: 40)
    end

    create(unique_index(:users, [:username]))
    create(unique_index(:users, [:email]))
  end
end
