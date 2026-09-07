defmodule GSMLG.Browser.Workers.RetentionWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :browser_maintenance,
    max_attempts: 3,
    unique: [period: 300, fields: [:worker], states: :incomplete]

  import Ecto.Query

  alias GSMLG.Browser.{Enabled, Job, JobEvent}
  alias GSMLG.Repo

  @terminal ~w(completed failed cancelled)
  @batch_size 500

  @impl Oban.Worker
  def perform(_job) do
    with :ok <- Enabled.ensure(),
         {:ok, cutoff} <- retention_cutoff() do
      ids =
        Repo.all(
          from(event in JobEvent,
            join: job in Job,
            on: job.id == event.job_id,
            where: job.status in ^@terminal and event.inserted_at < ^cutoff,
            order_by: [asc: event.inserted_at, asc: event.id],
            limit: @batch_size,
            select: event.id
          )
        )

      {deleted, _rows} = Repo.delete_all(from(event in JobEvent, where: event.id in ^ids))
      if deleted == @batch_size, do: {:snooze, 1}, else: :ok
    end
  end

  defp retention_cutoff do
    case Application.get_env(:gsmlg_browser, :event_retention_days, 30) do
      days when is_integer(days) and days > 0 ->
        {:ok, DateTime.add(DateTime.utc_now(), -days, :day)}

      _invalid ->
        {:error, "invalid_browser_retention"}
    end
  end
end
