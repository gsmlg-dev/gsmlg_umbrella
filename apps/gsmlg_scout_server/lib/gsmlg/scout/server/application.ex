defmodule GSMLG.Scout.Server.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        GSMLG.Scout.Server.AgentRegistry,
        GSMLG.Scout.Server.JobManager,
        maybe_rabbitmq_consumer(GSMLG.Scout.Server.ResultConsumer, queue: "results"),
        maybe_rabbitmq_consumer(GSMLG.Scout.Server.ResultConsumer, queue: "failed"),
        maybe_rabbitmq_consumer(GSMLG.Scout.Server.HeartbeatConsumer, queue: "heartbeat")
      ]
      |> Enum.reject(&is_nil/1)

    Supervisor.start_link(children, strategy: :one_for_one, name: GSMLG.Scout.Server.Supervisor)
  end

  defp maybe_rabbitmq_consumer(module, opts) do
    if GSMLG.Scout.RabbitMQ.enabled?() and
         Application.get_env(:gsmlg_scout_server, :consumers_enabled, true) do
      {module, opts}
    end
  end
end
