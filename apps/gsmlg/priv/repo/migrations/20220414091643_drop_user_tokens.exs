defmodule GSMLG.Repo.Migrations.DropUserTokens do
  use Ecto.Migration

  def change do
    drop_if_exists table(:user_tokens)
  end
end
