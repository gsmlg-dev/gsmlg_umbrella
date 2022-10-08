defmodule GSMLG_CouchDB.Node do
  alias GSMLG_CouchDB.Connection

  def membership() do
    Connection.get!("/_membership")
  end

  def all_nodes() do
    membership() |> Map.get(:all_nodes)
  end

  def cluster_nodes() do
    membership() |> Map.get(:cluster_nodes)
  end

  def node_info(node_name) do
    Connection.get!("/_node/" <> node_name)
  end

  def node_stats(node_name) do
    Connection.get!("/_node/" <> node_name <> "/_stats")
  end

  def node_prometheus(node_name) do
    Connection.get!("/_node/" <> node_name <> "/_prometheus")
  end

  def node_system(node_name) do
    Connection.get!("/_node/" <> node_name <> "/_system")
  end

  def node_restart(node_name) do
    Connection.post!("/_node/" <> node_name <> "/_restart")
  end

  def local_node(node_name) do
    Connection.get!("/_node/_local/_nodes/" <> node_name)
  end

  def add_node(node_name) do
    Connection.put!("/_node/_local/_nodes/" <> node_name)
  end

  def remove_node(node_name) do
    rev = local_node(node_name) |> Map.get(:_rev)
    Connection.delete!("/_node/_local/_nodes/" <> node_name <> "?rev=" <> rev)
  end
end
