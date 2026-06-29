defmodule GSMLG.Scout.Server do
  @moduledoc """
  Public server API for fetch job lifecycle operations.
  """

  alias GSMLG.Scout.Server.{AgentRegistry, JobManager}

  def submit_fetch(params), do: JobManager.submit(params)
  def get_fetch(job_id), do: JobManager.get(job_id)
  def list_fetches, do: JobManager.list()
  def fetch_sync(params), do: JobManager.fetch_sync(params)
  def list_agents, do: AgentRegistry.list_agents()
end
