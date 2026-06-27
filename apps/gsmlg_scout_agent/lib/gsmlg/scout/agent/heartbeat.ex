defmodule GSMLG.Scout.Agent.Heartbeat do
  @moduledoc false

  use GenServer
  require Logger

  alias GSMLG.Scout.RabbitMQ
  alias GSMLG.Scout.Settings

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    send(self(), :heartbeat)
    {:ok, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    heartbeat = GSMLG.Scout.Agent.status()

    if RabbitMQ.enabled?() do
      Logger.debug("[Agent] Sending heartbeat to RabbitMQ")
      _ = RabbitMQ.publish_heartbeat(heartbeat)
    end

    Process.send_after(self(), :heartbeat, interval_ms())
    {:noreply, state}
  end

  defp interval_ms do
    Settings.get()["agent"]["heartbeat_interval_ms"]
  end
end
