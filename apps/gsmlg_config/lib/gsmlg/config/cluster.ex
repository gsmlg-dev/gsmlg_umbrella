defmodule GSMLG.Config.Cluster do
  @moduledoc false

  @default_config %{
    enabled: false,
    strategy: "epmd",
    topology_name: "gsmlg",
    hosts: [],
    connect_interval: 30_000,
    gossip_port: 45_892,
    gossip_if_addr: "0.0.0.0",
    gossip_multicast_addr: "233.252.1.32",
    gossip_multicast_ttl: 1,
    gossip_secret: "",
    gossip_broadcast_only: false
  }

  @strategies %{
    "epmd" => Cluster.Strategy.Epmd,
    "gossip" => Cluster.Strategy.Gossip,
    "local_epmd" => Cluster.Strategy.LocalEpmd,
    "erlang_hosts" => Cluster.Strategy.ErlangHosts
  }

  def default_config, do: @default_config

  def normalize(config) when is_map(config) or is_list(config) do
    config = Enum.into(config || %{}, %{})

    %{
      enabled: truthy?(get(config, :enabled)),
      strategy: normalize_strategy(get(config, :strategy)),
      topology_name:
        present_string(get(config, :topology_name), Map.fetch!(@default_config, :topology_name)),
      hosts: normalize_hosts(get(config, :hosts)),
      connect_interval:
        positive_integer(
          get(config, :connect_interval),
          Map.fetch!(@default_config, :connect_interval)
        ),
      gossip_port:
        positive_integer(get(config, :gossip_port), Map.fetch!(@default_config, :gossip_port)),
      gossip_if_addr:
        present_string(get(config, :gossip_if_addr), Map.fetch!(@default_config, :gossip_if_addr)),
      gossip_multicast_addr:
        present_string(
          get(config, :gossip_multicast_addr),
          Map.fetch!(@default_config, :gossip_multicast_addr)
        ),
      gossip_multicast_ttl:
        positive_integer(
          get(config, :gossip_multicast_ttl),
          Map.fetch!(@default_config, :gossip_multicast_ttl)
        ),
      gossip_secret: string_value(get(config, :gossip_secret)),
      gossip_broadcast_only: truthy?(get(config, :gossip_broadcast_only))
    }
  end

  def normalize(_config), do: @default_config

  def topologies(config) do
    config = normalize(config)

    cond do
      not config.enabled ->
        []

      config.strategy == "epmd" and config.hosts == [] ->
        []

      true ->
        [
          {String.to_atom(config.topology_name),
           [
             strategy: Map.fetch!(@strategies, config.strategy),
             config: strategy_config(config)
           ]}
        ]
    end
  end

  defp strategy_config(%{strategy: "epmd"} = config) do
    [
      hosts: Enum.map(config.hosts, &String.to_atom/1),
      timeout: config.connect_interval
    ]
  end

  defp strategy_config(%{strategy: "erlang_hosts"} = config) do
    [timeout: config.connect_interval]
  end

  defp strategy_config(%{strategy: "local_epmd"}), do: []

  defp strategy_config(%{strategy: "gossip"} = config) do
    [
      port: config.gossip_port,
      if_addr: config.gossip_if_addr,
      multicast_addr: config.gossip_multicast_addr,
      multicast_ttl: config.gossip_multicast_ttl,
      secret: config.gossip_secret,
      broadcast_only: config.gossip_broadcast_only
    ]
  end

  defp get(config, key) do
    Map.get(config, key) || Map.get(config, Atom.to_string(key))
  end

  defp normalize_strategy(value) when is_atom(value),
    do: normalize_strategy(Atom.to_string(value))

  defp normalize_strategy(value) when is_binary(value) do
    if Map.has_key?(@strategies, value), do: value, else: Map.fetch!(@default_config, :strategy)
  end

  defp normalize_strategy(_value), do: Map.fetch!(@default_config, :strategy)

  defp normalize_hosts(nil), do: []

  defp normalize_hosts(value) when is_binary(value) do
    value
    |> String.split([",", "\n", "\r", "\t", " "], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_hosts(values) when is_list(values) do
    values
    |> Enum.map(&string_value/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_hosts(_value), do: []

  defp truthy?(value) when value in [true, "true", "1", 1, "on", "yes"], do: true
  defp truthy?(_value), do: false

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp positive_integer(_value, default), do: default

  defp present_string(value, default) do
    case string_value(value) |> String.trim() do
      "" -> default
      value -> value
    end
  end

  defp string_value(value) when is_binary(value), do: value
  defp string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp string_value(value) when is_integer(value), do: Integer.to_string(value)
  defp string_value(_value), do: ""
end
