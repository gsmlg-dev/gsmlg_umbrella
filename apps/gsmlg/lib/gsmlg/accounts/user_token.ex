defmodule GSMLG.Accounts.UserToken do
  use Ecto.Schema
  import Ecto.Changeset
  alias GSMLG.Accounts.User

  @primary_key {:id, Ecto.UUID, []}
  schema "user_tokens" do
    field(:create_time, :utc_datetime)
    field(:expire_at, :utc_datetime)
    # field :id, Ecto.UUID
    field(:token, :string)
    field(:token_type, :string)

    belongs_to(:user, User)

    timestamps()
  end

  @doc false
  def changeset(user_token, attrs) do
    user_token
    |> cast(attrs, [:id, :token, :token_type, :expire_at])
    |> validate_required([:token, :token_type])
  end

  def create_changeset(user_token, attrs) do
    changeset(user_token, attrs)
    |> put_change(:id, Ecto.UUID.generate())
    |> put_change(:create_time, DateTime.utc_now() |> DateTime.truncate(:second))
  end
end
