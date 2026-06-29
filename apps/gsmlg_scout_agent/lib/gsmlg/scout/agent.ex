defmodule GSMLG.Scout.Agent do
  @moduledoc """
  Public boundary for Scout agent fetch execution.
  """

  alias GSMLG.Scout.Agent.Executor
  alias GSMLG.Scout.Fetch.Job
  alias GSMLG.Scout.Settings

  def fetch(%Job{} = job), do: Executor.fetch(job)

  def fetch(params) when is_map(params) do
    with {:ok, job} <- Job.from_map(params) do
      fetch(job)
    end
  end

  def status do
    settings = Settings.get()
    agent = settings["agent"]

    %{
      agent_id: agent["id"],
      region: agent["region"],
      status: "healthy",
      running_jobs: GSMLG.Scout.Agent.LightpandaPool.running_count(),
      capacity: agent["capacity"],
      version: Application.spec(:gsmlg_scout_agent, :vsn) |> to_string(),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
