defmodule GSMLG.Browser.EventConsumer do
  @moduledoc false

  use GenServer

  alias GSMLG.Browser.{Enabled, EventStore}

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    if Enabled.ensure() == :ok do
      :ok = Phoenix.PubSub.subscribe(GSMLG.PubSub, "commander:events")
    end

    {:ok, %{event_store: Keyword.get(opts, :event_store, EventStore)}}
  end

  @impl true
  def handle_info({:commander_job_event, agent_id, event}, state) do
    _result = ingest(state.event_store, agent_id, event)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp ingest(event_store, agent_id, event) when is_function(event_store, 2),
    do: event_store.(agent_id, event)

  defp ingest(event_store, agent_id, event), do: event_store.ingest(agent_id, event)
end
