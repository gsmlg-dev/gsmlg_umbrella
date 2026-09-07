defmodule GSMLG.Browser.JobEvent do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]
  @events ~w(workflow.accepted workflow.started workflow.phase_changed intervention.required intervention.cleared artifact.available result.available workflow.failed workflow.cancelled workflow.completed)

  schema "browser_job_events" do
    field(:job_id, :binary_id)
    field(:remote_execution_id, Ecto.UUID)
    field(:sequence, :integer)
    field(:event, :string)
    field(:phase, :string)
    field(:metadata, :map, default: %{})
    field(:occurred_at, :utc_datetime_usec)
    timestamps()
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :job_id,
      :remote_execution_id,
      :sequence,
      :event,
      :phase,
      :metadata,
      :occurred_at
    ])
    |> validate_required([:job_id, :remote_execution_id, :sequence, :event])
    |> validate_number(:sequence, greater_than: 0)
    |> validate_inclusion(:event, @events)
    |> GSMLG.Browser.Sanitizer.validate_changeset(metadata: 16_384)
    |> foreign_key_constraint(:job_id)
    |> unique_constraint([:remote_execution_id, :sequence])
    |> unique_constraint([:job_id, :sequence])
  end
end
