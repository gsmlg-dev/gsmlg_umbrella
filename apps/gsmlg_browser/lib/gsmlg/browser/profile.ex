defmodule GSMLG.Browser.Profile do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]
  @runtime_statuses ~w(unknown running stopped unavailable)
  @automation_statuses ~w(available leased manual disabled)

  schema "browser_profiles" do
    field(:node_id, :binary_id)
    field(:external_id, :string)
    field(:name, :string)
    field(:backend, :string)
    field(:enabled, :boolean, default: true)
    field(:is_default, :boolean, default: false)
    field(:runtime_status, :string, default: "unknown")
    field(:automation_status, :string, default: "available")
    field(:locale, :string)
    field(:timezone, :string)
    field(:screen, :map, default: %{})
    field(:policy, :map, default: %{})
    field(:last_seen_at, :utc_datetime_usec)
    field(:last_error, :map)

    timestamps()
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :node_id,
      :external_id,
      :name,
      :backend,
      :enabled,
      :is_default,
      :runtime_status,
      :automation_status,
      :locale,
      :timezone,
      :screen,
      :policy,
      :last_seen_at,
      :last_error
    ])
    |> validate_required([:node_id, :external_id, :name, :backend])
    |> validate_length(:external_id, min: 1, max: 256)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:runtime_status, @runtime_statuses)
    |> validate_inclusion(:automation_status, @automation_statuses)
    |> GSMLG.Browser.Sanitizer.validate_changeset(
      screen: 4_096,
      policy: 16_384,
      last_error: 4_096
    )
    |> foreign_key_constraint(:node_id)
    |> unique_constraint([:node_id, :external_id])
    |> unique_constraint(:is_default, name: :browser_profiles_one_default_per_node_index)
  end
end
