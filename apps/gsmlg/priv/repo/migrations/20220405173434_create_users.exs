defmodule GSMLG.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    # Create users table with string primary key to match the User schema
    # The id is a 40-character string (UUID format) that's generated in the changeset
    create table(:users, primary_key: false) do
      add :id, :string, size: 40, primary_key: true
      add :username, :string
      add :name, :string
      add :email, :string
      add :password, :string
      add :password_salt, :string
      add :is_2fa_enabled, :boolean, default: false, null: false
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
