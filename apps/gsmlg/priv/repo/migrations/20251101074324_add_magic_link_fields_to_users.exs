defmodule GSMLG.Repo.Migrations.AddMagicLinkFieldsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :magic_link_token, :string
      add :magic_link_sent_at, :utc_datetime
      add :magic_link_confirmed_at, :utc_datetime
      add :email_confirmed_at, :utc_datetime
    end
  end
end
