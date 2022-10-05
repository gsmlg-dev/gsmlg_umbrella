defmodule GSMLG_CouchDB.Node do
  alias GSMLG_CouchDB.Connection

  def membership() do
    case Connection.get("/_membership") do
      {:ok, %{data: data}} ->
        Jason.decode!(data, keys: :atoms)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def all_nodes() do
    case membership() do
      {:error, reason} ->
        {:error, reason}

      data ->
        data.all_nodes
    end
  end

  def cluster_nodes() do
    case membership() do
      {:error, reason} ->
        {:error, reason}

      data ->
        data.all_nodes
    end
  end

  def add_node(node_name) do
    case Connection.request("PUT", "/_node/_local/_nodes/" <> node_name, %{}) do
      {:ok, %{data: data}} ->
        Jason.decode!(data, keys: :atoms)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Before you remove a node, make sure that you have moved all shards away from that node.
  # To remove node2 from server yyy.yyy.yyy.yyy,
  # you need to first know the revision of the document that signifies that node’s existence:
  #   > curl "http://xxx.xxx.xxx.xxx/_node/_local/_nodes/node2@yyy.yyy.yyy.yyy"
  #   > {"_id":"node2@yyy.yyy.yyy.yyy","_rev":"1-967a00dff5e02add41820138abb3284d"}
  # With that _rev, you can now proceed to delete the node document:
  #   > curl -X DELETE "http://xxx.xxx.xxx.xxx/_node/_local/_nodes/node2@yyy.yyy.yyy.yyy?rev=1-967a00dff5e02add41820138abb3284d"
  def remove_node(node_name) do
    case Connection.request("GET", "/_node/_local/_nodes/" <> node_name) do
      {:ok, %{data: data}} ->
        rev = Jason.decode!(data, keys: :atoms)._rev

        case Connection.request(
               "DELETE",
               "/_node/_local/_nodes/" <> node_name <> "?rev=" <> rev,
               %{}
             ) do
          {:ok, %{data: data}} ->
            Jason.decode!(data, keys: :atoms)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
