defmodule GSMLG.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :active_time, :utc_datetime
    field :apple_id, :string
    field :email, :string
    field :github_id, :string
    field :google_id, :string
    field :is_active, :boolean, default: false
    field :name, :string
    field :otp_token, :string
    field :password, :string
    field :password_salt, :string
    field :portrait, :string
    field :verify_code, :integer

    timestamps()
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :email, :password, :password_salt, :is_active, :otp_token, :verify_code, :portrait, :google_id, :apple_id, :github_id, :active_time])
    |> validate_required([:name, :email, :password, :password_salt, :is_active, :otp_token, :verify_code, :portrait, :google_id, :apple_id, :github_id, :active_time])
  end
end
