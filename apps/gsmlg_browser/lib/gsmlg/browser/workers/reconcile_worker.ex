defmodule GSMLG.Browser.Workers.ReconcileWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :browser_reconcile,
    max_attempts: 5,
    unique: [period: 30, fields: [:worker, :args], states: :incomplete]

  alias GSMLG.Browser.{Enabled, Job}
  alias GSMLG.Repo

  @active ~w(accepted unknown running waiting_human collecting_artifacts)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"job_id" => job_id}}) do
    with :ok <- Enabled.ensure() do
      case Repo.get(Job, job_id) do
        %Job{status: status} when status in @active -> reconcile(job_id)
        %Job{} -> :ok
        nil -> :discard
      end
    end
  end

  defp reconcile(job_id) do
    case GSMLG.Browser.reconcile_job_id(job_id) do
      {:ok, _job} -> :ok
      {:error, reason} when reason in [:node_offline, :rpc_timeout] -> {:snooze, 30}
      {:error, _reason} -> {:error, "browser_reconcile_failed"}
    end
  end
end
