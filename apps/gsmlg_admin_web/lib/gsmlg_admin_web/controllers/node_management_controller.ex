defmodule GSMLGAdminWeb.NodeManagementController do
  use GSMLGAdminWeb, :controller

  def index(conn, _params) do
    render(conn, "index.html", nodes: Node.list(), page_title: "Node Management")
  end

  def update(conn, %{"action" => "set-node-cookie", "cookie" => cookie} = _params) do
    case cookie |> String.to_atom() |> Node.set_cookie() do
      true ->
        conn
        |> put_flash(:info, "Update cookie success!")
        |> render(:index, nodes: Node.list(), page_title: "Node Management")
    end
  end

  def update(conn, %{"action" => "connect-node", "target_node" => target_node} = _params) do
    case target_node |> String.to_atom() |> Node.connect() do
      true ->
        conn
        |> put_flash(:info, "Connect to Node #{target_node} success!")
        |> render(:index, nodes: Node.list(), page_title: "Node Management")

      error ->
        conn
        |> put_flash(:error, inspect(error))
        |> render(:index, nodes: Node.list(), page_title: "Node Management")
    end
  end

  def update(conn, _params) do
    send_resp(conn, :no_content, "")
  end
end
