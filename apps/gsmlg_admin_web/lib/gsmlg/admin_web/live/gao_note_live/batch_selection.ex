defmodule GSMLG.AdminWeb.GaoNoteLive.BatchSelection do
  @moduledoc false

  @spec toggle(MapSet.t(), term()) :: MapSet.t()
  def toggle(%MapSet{} = selected, id) do
    if MapSet.member?(selected, id) do
      MapSet.delete(selected, id)
    else
      MapSet.put(selected, id)
    end
  end

  @spec toggle_all(MapSet.t(), Enumerable.t()) :: MapSet.t()
  def toggle_all(%MapSet{} = selected, loaded_ids) do
    loaded = MapSet.new(loaded_ids)

    if MapSet.subset?(loaded, selected) do
      MapSet.difference(selected, loaded)
    else
      MapSet.union(selected, loaded)
    end
  end

  @spec reconcile(MapSet.t(), Enumerable.t()) :: MapSet.t()
  def reconcile(%MapSet{} = selected, loaded_ids) do
    MapSet.intersection(selected, MapSet.new(loaded_ids))
  end

  @spec state(MapSet.t(), Enumerable.t()) :: :none | :mixed | :all
  def state(%MapSet{}, []), do: :none

  def state(%MapSet{} = selected, loaded_ids) do
    loaded = MapSet.new(loaded_ids)

    cond do
      MapSet.disjoint?(selected, loaded) -> :none
      MapSet.subset?(loaded, selected) -> :all
      true -> :mixed
    end
  end
end
