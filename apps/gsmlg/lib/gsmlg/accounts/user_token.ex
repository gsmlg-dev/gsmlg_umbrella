defmodule GSMLG.Accounts.UserToken do
  use Ecto.Schema
  import Ecto.Changeset
  alias GSMLG.Accounts.User

  @primary_key {:jti, :string, autogenerate: false}
  schema "user_tokens" do
    field(:aud, :string)
    field(:typ, :string)
    field(:iss, :string)
    field(:sub, :string)
    field(:exp, :integer)
    field(:jwt, :string)
    field(:claims, :map)
    belongs_to(:user, User, define_field: false, foreign_key: :sub)
    timestamps()
  end

  @doc false
  def changeset(user_token, attrs) do
    user_token
    |> cast(attrs, [:jti, :aud, :typ, :iss, :sub, :exp, :jwt, :claims])
    |> validate_required([:jti, :aud])
  end

  def update_changeset(user_token, attrs) do
    user_token
    |> cast(attrs, [:aud, :typ, :iss, :sub, :exp, :jwt, :claims])
    |> validate_required([:jwt, :iss])
  end
end
