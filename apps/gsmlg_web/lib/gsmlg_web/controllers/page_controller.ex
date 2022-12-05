defmodule GSMLGWeb.PageController do
  use GSMLGWeb, :controller

  def index(conn, _params) do
    repos =
      GSMLG.GitHub.repos()
      |> Enum.sort(&(&1.stargazers_count > &2.stargazers_count))

    paget_title =
      Application.get_env(:gsmlg_web, GSMLGWeb.Endpoint) |> Keyword.get(:home_page_title)

    render(conn, :index, page_title: paget_title, repos: repos)
  end

  def not_found(conn, _params) do
    case handle_path(conn.request_path) do
      {:html, file} ->
        conn
        |> put_resp_header("content-type", "text/html; charset=utf-8")
        |> Plug.Conn.send_file(200, file)

      {:not_found_page, file} ->
        conn
        |> put_resp_header("content-type", "text/html; charset=utf-8")
        |> Plug.Conn.send_file(404, file)

      _ ->
        conn
        |> put_status(:not_found)
        |> render(:"404", page_title: "404 Page Not Found")
    end
  end

  defp handle_path(path) do
    path = if path == "/", do: "/index", else: path

    cond do
      File.exists?(
        file_path =
            Path.join([Application.app_dir(:gsmlg_web), "priv", "static", path <> ".html"])
      ) ->
        {:html, file_path}

      File.exists?(
        file_path =
            Path.join([Application.app_dir(:gsmlg_web), "priv", "static", path, "/index.html"])
      ) ->
        {:html, file_path}

      File.exists?(
        file_path = Path.join([Application.app_dir(:gsmlg_web), "priv", "static", "404.html"])
      ) ->
        {:not_found_page, file_path}

      true ->
        {:null, nil}
    end
  end
end
