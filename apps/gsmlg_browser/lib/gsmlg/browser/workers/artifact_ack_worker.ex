defmodule GSMLG.Browser.Workers.ArtifactAckWorker do
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
        %Artifact{status: "verified"} = artifact ->
          case ArtifactService.retry_ack(artifact) do
            {:ok, %Artifact{ack_status: "acked"}} -> :ok
            {:ok, _pending} -> {:snooze, 30}
            {:error, _reason} -> {:snooze, 30}
          end

        %Artifact{} ->
          :ok

        nil ->
          :discard
      end
    end
  end
end
