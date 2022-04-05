defmodule GSMLG.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :username, :string
      add :name, :string
      add :email, :string
      add :password, :string
      add :password_salt, :string
      add :is_active, :boolean, default: false, null: false
      add :otp_token, :string
      add :verify_code, :integer
      add :portrait, :string
      add :google_id, :string
      add :apple_id, :string
      add :github_id, :string
      add :active_time, :utc_datetime

      timestamps()
    end
  end
end
