defmodule GSMLG.Accounts.UserToken do
  use Ecto.Schema
  import Ecto.Changeset
  alias GSMLG.Accounts.User

  @primary_key false
  schema "user_tokens" do
    field :create_time, :utc_datetime
    field :expire_at, :utc_datetime
    field :id, Ecto.UUID
    field :token, :string
    field :token_type, :string
    # field :user_id, :id

    belongs_to :user, User

    timestamps()
  end

  @doc false
  def changeset(user_token, attrs) do
    user_token
    |> cast(attrs, [:id, :token, :token_type, :create_time, :expire_at])
    |> validate_required([:id, :token, :token_type, :create_time, :expire_at])
  end
end
