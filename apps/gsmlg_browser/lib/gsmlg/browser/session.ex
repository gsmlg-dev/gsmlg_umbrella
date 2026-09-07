defmodule GSMLG.Browser.Session do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]
  @modes ~w(automation manual)
  @statuses ~w(opening ready acting waiting waiting_human closing closed orphaned failed)

  schema "browser_sessions" do
    field(:node_id, :binary_id)
    field(:profile_id, :binary_id)
    field(:remote_session_id, Ecto.UUID)
    field(:lease_id, Ecto.UUID)
    field(:mode, :string)
    field(:status, :string)
    field(:origin_policy, :map, default: %{})
    field(:revision, :integer, default: 0)
    field(:owner_actor_id, :string)
    field(:last_seen_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:error, :map)

    timestamps()
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :node_id,
      :profile_id,
      :remote_session_id,
      :lease_id,
      :mode,
      :status,
      :origin_policy,
      :revision,
      :owner_actor_id,
      :last_seen_at,
      :expires_at,
      :error
    ])
    |> validate_required([:node_id, :profile_id, :mode, :status, :owner_actor_id, :expires_at])
    |> validate_inclusion(:mode, @modes)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:revision, greater_than_or_equal_to: 0)
    |> GSMLG.Browser.Sanitizer.validate_changeset(origin_policy: 16_384, error: 4_096)
    |> foreign_key_constraint(:node_id)
    |> foreign_key_constraint(:profile_id)
    |> foreign_key_constraint(:owner_actor_id)
    |> unique_constraint(:remote_session_id)
  end
end
