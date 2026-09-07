defmodule GSMLG.Browser.Job do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]
  @statuses ~w(queued dispatching accepted unknown running waiting_human collecting_artifacts completed failed cancelled)

  schema "browser_jobs" do
    field(:node_id, :binary_id)
    field(:profile_id, :binary_id)
    field(:session_id, :binary_id)
    field(:remote_execution_id, Ecto.UUID)
    field(:workflow, :string)
    field(:workflow_version, :integer)
    field(:status, :string)
    field(:phase, :string)
    field(:input, :map, default: %{})
    field(:output_formats, {:array, :string}, default: [])
    field(:idempotency_key, :string)
    field(:attempt, :integer, default: 1)
    field(:previous_job_id, :binary_id)
    field(:last_remote_sequence, :integer, default: 0)
    field(:control_keys, :map, default: %{})
    field(:chat_url, :string)
    field(:result, :map)
    field(:error, :map)
    field(:requested_by_actor_id, :string)
    field(:deadline_at, :utc_datetime_usec)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)

    timestamps()
  end

  def create_changeset(job, attrs) do
    job
    |> cast(attrs, [
      :node_id,
      :profile_id,
      :session_id,
      :remote_execution_id,
      :workflow,
      :workflow_version,
      :status,
      :phase,
      :input,
      :output_formats,
      :idempotency_key,
      :attempt,
      :previous_job_id,
      :last_remote_sequence,
      :control_keys,
      :chat_url,
      :result,
      :error,
      :requested_by_actor_id,
      :deadline_at,
      :started_at,
      :completed_at
    ])
    |> validate_required([
      :node_id,
      :profile_id,
      :workflow,
      :workflow_version,
      :status,
      :idempotency_key,
      :requested_by_actor_id,
      :deadline_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:workflow_version, greater_than: 0)
    |> validate_number(:attempt, greater_than: 0)
    |> validate_number(:last_remote_sequence, greater_than_or_equal_to: 0)
    |> validate_length(:idempotency_key, min: 1, max: 512)
    |> validate_chat_url()
    |> validate_lineage()
    |> GSMLG.Browser.Sanitizer.validate_changeset(
      control_keys: 8_192,
      result: 16_384,
      error: 4_096
    )
    |> foreign_key_constraint(:node_id)
    |> foreign_key_constraint(:profile_id)
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:requested_by_actor_id)
    |> foreign_key_constraint(:previous_job_id)
    |> unique_constraint(:idempotency_key, name: :browser_jobs_actor_idempotency_index)
    |> unique_constraint(:remote_execution_id)
    |> unique_constraint(:previous_job_id, name: :browser_jobs_linear_retry_index)
  end

  def transition_changeset(job, attrs) do
    job
    |> cast(attrs, [
      :session_id,
      :remote_execution_id,
      :status,
      :phase,
      :last_remote_sequence,
      :control_keys,
      :chat_url,
      :result,
      :error,
      :started_at,
      :completed_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:last_remote_sequence, greater_than_or_equal_to: 0)
    |> validate_chat_url()
    |> GSMLG.Browser.Sanitizer.validate_changeset(
      control_keys: 8_192,
      result: 16_384,
      error: 4_096
    )
    |> unique_constraint(:remote_execution_id)
  end

  defp validate_lineage(changeset) do
    attempt = get_field(changeset, :attempt)
    previous_job_id = get_field(changeset, :previous_job_id)

    if (attempt == 1 and is_nil(previous_job_id)) or
         (is_integer(attempt) and attempt > 1 and not is_nil(previous_job_id)) do
      changeset
    else
      add_error(changeset, :attempt, "does not match retry lineage")
    end
  end

  defp validate_chat_url(changeset) do
    validate_change(changeset, :chat_url, fn :chat_url, value ->
      case GSMLG.Browser.ChatURL.validate(value) do
        {:ok, _url} -> []
        {:error, _reason} -> [chat_url: "is not an approved Gemini HTTPS URL"]
      end
    end)
  end
end
