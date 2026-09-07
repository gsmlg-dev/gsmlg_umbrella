defmodule GSMLG.Browser.Workers.ArtifactTransferWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :browser_artifacts,
    max_attempts: 10,
    unique: [period: 60, fields: [:worker, :args], states: :incomplete]

  alias GSMLG.Browser.{Artifact, ArtifactService, Enabled}
  alias GSMLG.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"artifact_id" => artifact_id}}) do
    with :ok <- Enabled.ensure() do
      case Repo.get(Artifact, artifact_id) do
        %Artifact{status: "pending", transfer_mode: "remote_pending"} = artifact ->
          transfer(artifact)

        %Artifact{status: "uploading"} = artifact ->
          case ArtifactService.reset_expired_upload(artifact) do
            {:ok, %Artifact{status: "pending"} = pending} -> transfer(pending)
            {:ok, _uploading} -> {:snooze, 30}
            {:error, _reason} -> {:error, "browser_artifact_reset_failed"}
          end

        %Artifact{status: "verified"} = artifact ->
          retry_ack(artifact)

        %Artifact{} ->
          :ok

        nil ->
          :discard
      end
    end
  end

  defp transfer(artifact) do
    case ArtifactService.transfer_pending(artifact) do
      {:ok, _artifact} -> :ok
      {:error, reason} when reason in [:node_offline, :rpc_timeout] -> {:snooze, 30}
      {:error, _reason} -> {:error, "browser_artifact_transfer_failed"}
    end
  end

  defp retry_ack(artifact) do
    case ArtifactService.retry_ack(artifact) do
      {:ok, _artifact} -> :ok
      {:error, reason} when reason in [:node_offline, :rpc_timeout] -> {:snooze, 30}
      {:error, _reason} -> {:error, "browser_artifact_ack_failed"}
    end
  end
end
