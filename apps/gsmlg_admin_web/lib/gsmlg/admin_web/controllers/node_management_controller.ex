defmodule GSMLG.AdminWeb.NodeManagementController do
  use GSMLG.AdminWeb, :controller

  alias GSMLG.Cluster
  alias GSMLG.Node.Others
  alias GSMLG.Node.Self

  def index(conn, _params) do
    render(conn, :index, page_assigns())
  end

  def update(conn, %{"action" => "set-node-cookie", "cookie" => cookie} = _params) do
    with {:ok, cookie} <- atom_from_input(cookie),
         true <- Node.set_cookie(cookie) do
      conn
      |> put_flash(:info, "Update cookie success!")
      |> redirect(to: ~p"/node_management")
    else
      {:error, :blank} ->
        conn
        |> put_flash(:error, "Node cookie cannot be blank.")
        |> redirect(to: ~p"/node_management")

      false ->
        conn
        |> put_flash(:error, "Update cookie failed.")
        |> redirect(to: ~p"/node_management")
    end
  end

  def update(conn, %{"action" => "connect-node", "target_node" => target_node} = _params) do
    with {:ok, node} <- atom_from_input(target_node),
         true <- Node.connect(node) do
      conn
      |> put_flash(:info, "Connect to Node #{target_node} success!")
      |> redirect(to: ~p"/node_management")
    else
      {:error, :blank} ->
        conn
        |> put_flash(:error, "Target node cannot be blank.")
        |> redirect(to: ~p"/node_management")

      error ->
        conn
        |> put_flash(:error, inspect(error))
        |> redirect(to: ~p"/node_management")
    end
  end

  def update(conn, %{"action" => "disconnect-node", "target_node" => target_node} = _params) do
    with {:ok, node} <- atom_from_input(target_node),
         true <- Node.disconnect(node) do
      conn
      |> put_flash(:info, "Disconnect from Node #{target_node} success!")
      |> redirect(to: ~p"/node_management")
    else
      {:error, :blank} ->
        conn
        |> put_flash(:error, "Target node cannot be blank.")
        |> redirect(to: ~p"/node_management")

      false ->
        conn
        |> put_flash(:error, "Disconnect from Node #{target_node} failed.")
        |> redirect(to: ~p"/node_management")
    end
  end

  def update(conn, %{"action" => "start-node"} = _params) do
    case Self.start() do
      {:ok, _state} ->
        conn
        |> put_flash(:info, "Distributed node started.")
        |> redirect(to: ~p"/node_management")

      error ->
        conn
        |> put_flash(:error, inspect(error))
        |> redirect(to: ~p"/node_management")
    end
  end

  def update(conn, %{"action" => "stop-node"} = _params) do
    case Self.stop() do
      {:ok, _state} ->
        conn
        |> put_flash(:info, "Distributed node stopped.")
        |> redirect(to: ~p"/node_management")

      error ->
        conn
        |> put_flash(:error, inspect(error))
        |> redirect(to: ~p"/node_management")
    end
  end

  def update(conn, %{"action" => "configure-cluster"} = params) do
    params
    |> Cluster.params_to_config()
    |> Cluster.apply_runtime()
    |> case do
      {:ok, config} ->
        message =
          if config.enabled do
            "Cluster configuration applied."
          else
            "Cluster configuration disabled."
          end

        conn
        |> put_flash(:info, message)
        |> redirect(to: ~p"/node_management")

      {:error, reason, _config} ->
        conn
        |> put_flash(:error, "Cluster configuration failed: #{inspect(reason)}")
        |> redirect(to: ~p"/node_management")
    end
  end

  def update(conn, _params) do
    send_resp(conn, :no_content, "")
  end

  defp page_assigns do
    cluster_status = Cluster.status()
    cluster_form = Cluster.form_data(cluster_status.config)

    [
      nodes: Node.list(),
      tracked_nodes: tracked_nodes(),
      node_state: node_state(),
      cluster_status: cluster_status,
      cluster_form: Phoenix.Component.to_form(cluster_form),
      cluster_strategy_options: Cluster.strategy_options(),
      page_title: "Node Management"
    ]
  end

  defp node_state do
    if Process.whereis(Self) do
      Self.get_state()
    else
      %{alive?: Node.alive?(), self: Node.self(), pid: nil, restart?: false}
    end
  end

  defp tracked_nodes do
    if Process.whereis(Others), do: Others.get_nodes(), else: []
  end

  defp atom_from_input(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :blank}
      value -> {:ok, String.to_atom(value)}
    end
  end

  defp atom_from_input(_value), do: {:error, :blank}
end
