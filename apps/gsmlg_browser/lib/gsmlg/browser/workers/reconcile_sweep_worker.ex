defmodule GSMLG.Browser.Workers.ReconcileSweepWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :browser_reconcile,
    max_attempts: 1,
    unique: [period: 30, fields: [:worker], states: :incomplete]

  import Ecto.Query

  alias GSMLG.Browser.{Artifact, Enabled, Job}
  alias GSMLG.Browser.Workers.{ArtifactAckWorker, ArtifactTransferWorker, ReconcileWorker}
  alias GSMLG.Repo

  @active ~w(accepted unknown running waiting_human collecting_artifacts)
  @batch_size 100

  @impl Oban.Worker
  def perform(_oban_job) do
    with :ok <- Enabled.ensure(),
         :ok <- enqueue_jobs(),
         :ok <- enqueue_ack_retries(),
         :ok <- enqueue_artifact_transfers() do
      :ok
    end
  end

  defp enqueue_jobs do
    Repo.all(
      from(job in Job,
        where: job.status in ^@active,
        order_by: [asc: job.updated_at, asc: job.id],
        limit: @batch_size,
        select: job.id
      )
    )
    |> enqueue(fn id -> ReconcileWorker.new(%{"job_id" => id}) end)
  end

  defp enqueue_ack_retries do
    Repo.all(
      from(artifact in Artifact,
        where: artifact.status == "verified" and artifact.ack_status == "pending",
        order_by: [asc: artifact.inserted_at, asc: artifact.id],
        limit: @batch_size,
        select: artifact.id
      )
    )
    |> enqueue(fn id -> ArtifactAckWorker.new(%{"artifact_id" => id}) end)
  end

  defp enqueue_artifact_transfers do
    now = DateTime.utc_now()

    Repo.all(
      from(artifact in Artifact,
        where:
          (artifact.status == "pending" and artifact.transfer_mode == "remote_pending") or
            (artifact.status == "uploading" and artifact.upload_expires_at < ^now),
        order_by: [asc: artifact.inserted_at, asc: artifact.id],
        limit: @batch_size,
        select: artifact.id
      )
    )
    |> enqueue(fn id -> ArtifactTransferWorker.new(%{"artifact_id" => id}) end)
  end

  defp enqueue(ids, builder) do
    Enum.reduce_while(ids, :ok, fn id, :ok ->
      case Oban.insert(builder.(id)) do
        {:ok, _job} -> {:cont, :ok}
        {:error, _changeset} -> {:halt, {:error, "browser_sweep_enqueue_failed"}}
      end
    end)
  end
end
