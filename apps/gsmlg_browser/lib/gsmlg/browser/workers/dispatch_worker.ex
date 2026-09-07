defmodule GSMLG.Browser.Workers.DispatchWorker do
  @moduledoc false
  use Oban.Worker, queue: :browser_dispatch, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"job_id" => job_id}}) do
    with :ok <- GSMLG.Browser.Enabled.ensure() do
      case GSMLG.Browser.Dispatcher.dispatch(job_id) do
        {:ok, _job} -> :ok
        {:error, _reason} -> {:error, "browser_dispatch_failed"}
      end
    end
  end
end
