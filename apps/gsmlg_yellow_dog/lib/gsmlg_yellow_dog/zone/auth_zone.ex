defmodule GSMLGYellowDog.Zone.AuthZone do
  @moduledoc """
  Example implementing GSMLGDNS.Zone behaviour
  """
  def getZone(domain) do
  end

  def findByDomain(domain, type) do
    list = domain |> to_string |> String.split(".") |> Enum.reverse()

    case list do
      ["tld", "sld" | rest] ->
        r = %GSMLGDNS.Resource{
          domain: domain,
          type: type,
          ttl: 0,
          data: {1, 2, 3, 4}
        }

        if type == :a do
          {:ok, [r]}
        else
          {:ok, []}
        end

      ["com", "gsmlg" | rest] ->
        r = %GSMLGDNS.Resource{
          domain: domain,
          type: type,
          ttl: 0,
          data: {1, 2, 3, 4}
        }

        {:ok, [r]}

      _ ->
        {:nxdomain}
    end
  end
end
