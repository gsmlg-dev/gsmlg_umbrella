defmodule GSMLG.Scout.Server.Dispatcher do
  @moduledoc """
  Dispatches Scout fetch jobs to either RabbitMQ or the local executor.
  """

  alias GSMLG.Scout.Fetch.Job

  def dispatch(%Job{} = job) do
    publisher().publish_job(job)
  end

  defp publisher do
    Application.get_env(:gsmlg_scout_server, :job_publisher) ||
      if GSMLG.Scout.RabbitMQ.enabled?() do
        GSMLG.Scout.RabbitMQ
      else
        GSMLG.Scout.Server.TransportDisabled
      end
  end
end
