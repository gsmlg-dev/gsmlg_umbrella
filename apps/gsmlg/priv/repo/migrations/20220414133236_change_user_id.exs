defmodule GSMLG.Repo.Migrations.ChangeUserId do
  use Ecto.Migration

  def change do
    # Note: The original create_users migration has been updated to create
    # the id column as :string from the start. This migration is now only
    # responsible for creating the unique indexes.
    #
    # For existing databases that still have bigint id, this will fail and
    # needs to be handled manually (data migration required).

    # Only create indexes - the id column should already be :string
    # from the create_users migration
    create_if_not_exists(unique_index(:users, [:username]))
    create_if_not_exists(unique_index(:users, [:email]))
  end
end
