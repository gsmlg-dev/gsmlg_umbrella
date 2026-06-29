defmodule GSMLG.Scout.Agent.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    if agent_enabled?() do
      children =
        [
          {Task.Supervisor, name: GSMLG.Scout.Agent.TaskSupervisor},
          GSMLG.Scout.Agent.LightpandaPool,
          GSMLG.Scout.Agent.Heartbeat,
          maybe_rabbitmq_consumer()
        ]
        |> Enum.reject(&is_nil/1)

      Supervisor.start_link(children, strategy: :one_for_one, name: GSMLG.Scout.Agent.Supervisor)
    else
      Supervisor.start_link([], strategy: :one_for_one, name: GSMLG.Scout.Agent.Supervisor)
    end
  end

  defp agent_enabled? do
    settings = GSMLG.Scout.Settings.get()

    settings["agent"]["enabled"] == true ||
      System.get_env("GSMLG_SCOUT_AGENT_ENABLED") == "true" ||
      Application.get_env(:gsmlg_scout_agent, :force_enabled, false)
  end

  defp maybe_rabbitmq_consumer do
    if GSMLG.Scout.RabbitMQ.enabled?() and
         Application.get_env(:gsmlg_scout_agent, :consumer_enabled, true) do
      GSMLG.Scout.Agent.AMQPConsumer
    end
  end
end
