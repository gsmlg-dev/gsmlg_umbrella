defmodule GSMLG.Cluster do
  @moduledoc """
  Runtime libcluster configuration for GSMLG node management.
  """

  @supervisor GSMLG.Cluster.Supervisor

  defdelegate default_config, to: GSMLG.Config.Cluster
  defdelegate normalize(config), to: GSMLG.Config.Cluster
  defdelegate topologies(config), to: GSMLG.Config.Cluster

  def config do
    :gsmlg
    |> Application.get_env(:cluster, default_config())
    |> normalize()
  end

  def configure(config) do
    config = normalize(config)
    topologies = topologies(config)

    Application.put_env(:gsmlg, :cluster, config)
    Application.put_env(:libcluster, :topologies, topologies)

    config
  end

  def apply_runtime(config) do
    config = configure(config)

    with :ok <- stop_runtime_supervisor() do
      case child_spec(config) do
        nil -> {:ok, config}
        spec -> start_runtime_supervisor(spec, config)
      end
    end
  end

  def status do
    config = config()

    %{
      config: config,
      enabled?: config.enabled,
      running?: running?(),
      supervisor: @supervisor,
      topologies: Application.get_env(:libcluster, :topologies, topologies(config)),
      connected_nodes: Node.list()
    }
  end

  def child_specs(config \\ config()) do
    case child_spec(config) do
      nil -> []
      spec -> [spec]
    end
  end

  def child_spec(config \\ config()) do
    case topologies(config) do
      [] ->
        nil

      topologies ->
        %{
          id: @supervisor,
          start: {Cluster.Supervisor, :start_link, [[topologies, [name: @supervisor]]]},
          type: :supervisor
        }
    end
  end

  def params_to_config(params) do
    params
    |> Map.take([
      "enabled",
      "strategy",
      "topology_name",
      "hosts",
      "connect_interval",
      "gossip_port",
      "gossip_if_addr",
      "gossip_multicast_addr",
      "gossip_multicast_ttl",
      "gossip_secret",
      "gossip_broadcast_only"
    ])
    |> normalize()
  end

  def form_data(config \\ config()) do
    config = normalize(config)

    %{
      "enabled" => config.enabled,
      "strategy" => config.strategy,
      "topology_name" => config.topology_name,
      "hosts" => Enum.join(config.hosts, "\n"),
      "connect_interval" => config.connect_interval,
      "gossip_port" => config.gossip_port,
      "gossip_if_addr" => config.gossip_if_addr,
      "gossip_multicast_addr" => config.gossip_multicast_addr,
      "gossip_multicast_ttl" => config.gossip_multicast_ttl,
      "gossip_secret" => config.gossip_secret,
      "gossip_broadcast_only" => config.gossip_broadcast_only
    }
  end

  def strategy_options do
    [
      {"epmd", "EPMD static hosts"},
      {"gossip", "Gossip"},
      {"local_epmd", "Local EPMD"},
      {"erlang_hosts", ".hosts.erlang"}
    ]
  end

  def running?, do: Process.whereis(@supervisor) != nil

  defp stop_runtime_supervisor do
    case Process.whereis(GSMLG.Node.Supervisor) do
      nil ->
        :ok

      _pid ->
        with :ok <- terminate_child(),
             :ok <- delete_child() do
          :ok
        end
    end
  end

  defp terminate_child do
    case Supervisor.terminate_child(GSMLG.Node.Supervisor, @supervisor) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, :not_started} -> :ok
      {:error, reason} -> {:error, reason, config()}
    end
  end

  defp delete_child do
    case Supervisor.delete_child(GSMLG.Node.Supervisor, @supervisor) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, :running} -> {:error, :cluster_supervisor_still_running, config()}
      {:error, reason} -> {:error, reason, config()}
    end
  end

  defp start_runtime_supervisor(spec, config) do
    case Process.whereis(GSMLG.Node.Supervisor) do
      nil ->
        {:error, :node_supervisor_not_running, config}

      _pid ->
        case Supervisor.start_child(GSMLG.Node.Supervisor, spec) do
          {:ok, _pid} -> {:ok, config}
          {:ok, _pid, _info} -> {:ok, config}
          {:error, {:already_started, _pid}} -> {:ok, config}
          {:error, reason} -> {:error, reason, config}
        end
    end
  end
end
