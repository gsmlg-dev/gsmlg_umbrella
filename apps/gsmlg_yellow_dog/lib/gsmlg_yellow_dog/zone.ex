defmodule GSMLGYellowDog.Zone do
  @moduledoc """
  GSMLGYellowDog.Zone
  """

  def findByDomain(domain, _type) do
    {:ok, zones} = GSMLGYellowDog.Zone.Registry.get_zones()

    zone =
      Enum.find(zones, fn {name, _} ->
        name == domain || String.ends_with?(domain, ".#{name}")
      end)

    case zone do
      nil ->
        {:refused}

      zone when is_binary(zone) ->
        rrs = []
        {:noerror, rrs}
    end
  end
end
