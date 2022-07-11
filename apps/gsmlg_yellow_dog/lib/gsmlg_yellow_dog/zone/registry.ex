defmodule GSMLGYellowDog.Zone.Registry do
  @moduledoc """
  Example implementing GSMLGDNS.Zone behaviour
  """
  use GenServer

  @spec start_link(any) :: :ignore | {:error, any} | {:ok, pid}
  def start_link(args \\ []) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @spec register_zone(binary()) :: any
  def register_zone(zone_name) do
    GenServer.call(__MODULE__, {:register_zone, zone_name})
  end

  def get_zones() do
    GenServer.call(__MODULE__, :get_zones)
  end

  @impl true
  def init(_) do
    state = %{zones: []}

    {:ok, state}
  end

  @impl true
  def handle_call(:get_zones, _from, state) do
    zones = Map.get(state, :zones)
    {:reply, {:ok, zones}, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_call({:register_zone, zone}, _from, state) do
    zones = Map.get(state, :zones)
    len = zone |> String.split(".") |> length
    len = if zone == ".", do: 0, else: len
    zones = [{zone, len} | zones]
    state = Map.put(state, :zones, zones)
    {:reply, {:ok, zone}, state}
  end
end
