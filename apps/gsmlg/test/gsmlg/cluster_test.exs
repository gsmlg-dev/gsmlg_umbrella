defmodule GSMLG.ClusterTest do
  use ExUnit.Case, async: true

  describe "topologies/1" do
    test "does not configure libcluster when disabled" do
      assert GSMLG.Cluster.topologies(%{enabled: false, strategy: "gossip"}) == []
    end

    test "builds an epmd topology from host strings" do
      config = %{
        enabled: true,
        strategy: "epmd",
        topology_name: "production",
        hosts: ["gsmlg@10.100.10.10", "gsmlg@10.100.10.11"],
        connect_interval: 30_000
      }

      assert [
               production: [
                 strategy: Cluster.Strategy.Epmd,
                 config: [
                   hosts: [:"gsmlg@10.100.10.10", :"gsmlg@10.100.10.11"],
                   timeout: 30_000
                 ]
               ]
             ] = GSMLG.Cluster.topologies(config)
    end

    test "builds a gossip topology from multicast fields" do
      config = %{
        enabled: true,
        strategy: "gossip",
        topology_name: "lan",
        gossip_port: 45_892,
        gossip_if_addr: "0.0.0.0",
        gossip_multicast_addr: "233.252.1.32",
        gossip_multicast_ttl: 1,
        gossip_secret: "shared-secret",
        gossip_broadcast_only: false
      }

      assert [
               lan: [
                 strategy: Cluster.Strategy.Gossip,
                 config: [
                   port: 45_892,
                   if_addr: "0.0.0.0",
                   multicast_addr: "233.252.1.32",
                   multicast_ttl: 1,
                   secret: "shared-secret",
                   broadcast_only: false
                 ]
               ]
             ] = GSMLG.Cluster.topologies(config)
    end
  end
end
