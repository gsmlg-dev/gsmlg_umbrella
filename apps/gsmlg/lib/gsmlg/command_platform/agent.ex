defmodule GSMLG.CommandPlatform.Agent do
  require Logger
  use Agent

  def start_link(initial_value) do
    Agent.start_link(fn -> initial_value end, name: __MODULE__)
  end

  def commanders do
    Agent.get(__MODULE__, &Map.get(&1, :commanders, []))
  end

  def add_commander(commander) do
    Agent.update(
      __MODULE__,
      &Map.update!(&1, :commanders, fn commanders ->
        commanders ++ [commander]
      end)
    )
  end

  def remove_commander(commander) do
    Agent.update(
      __MODULE__,
      &Map.update!(&1, :commanders, fn commanders ->
        commanders |> Enum.reject(fn c -> c[:name] == commander[:name] end)
      end)
    )
  end
end
