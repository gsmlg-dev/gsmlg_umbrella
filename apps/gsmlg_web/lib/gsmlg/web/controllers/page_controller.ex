defmodule GSMLG.Web.PageController do
  use GSMLG.Web, :controller

  def index(conn, _params) do
    orgs = [
      "gsmlg-dev",
      "gsmlg-opt",
      "gsmlg-app",
      "gsmlg-ci",
      "duskmoon-dev",
      "Gao-OS"
    ]

    users = ["gsmlg"]

    org_r =
      orgs
      |> Enum.map(fn org ->
        case GSMLG.GitHub.fetch_repos_cache(org, is_user: false) do
          {:ok, repos} ->
            key = "stargazers_count"
            repos = repos |> Enum.sort(&(&1[key] > &2[key]))
            {org, repos}

          {:error, _} ->
            {org, []}
        end
      end)

    user_r =
      users
      |> Enum.map(fn user ->
        case GSMLG.GitHub.fetch_repos_cache(user, is_user: true) do
          {:ok, repos} ->
            key = "stargazers_count"
            repos = repos |> Enum.sort(&(&1[key] > &2[key]))
            {user, repos}

          {:error, _} ->
            {user, []}
        end
      end)

    group_repos = org_r ++ user_r

    active_repo_group =
      case group_repos do
        [{group, _repos} | _] -> group
        [] -> nil
      end

    # Phoenix 1.8: Use existing root layout template with embedded templates
    conn
    |> render(:index,
      page_title: gettext("Home"),
      group_repos: group_repos,
      active_repo_group: active_repo_group
    )
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
        |> render(:"404", page_title: dgettext("errors", "404 Page Not Found"))
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
