defmodule GSMLG.Repo do
  use Ecto.Repo,
    otp_app: :gsmlg,
    adapter: Ecto.Adapters.Postgres

  @impl true
  def init(_type, config) do
    # Configure to use naive_datetime for migration timestamps
    # This ensures compatibility when migrating from MySQL to PostgreSQL
    {:ok, Keyword.put(config, :migration_timestamps, type: :naive_datetime)}
  end
end
