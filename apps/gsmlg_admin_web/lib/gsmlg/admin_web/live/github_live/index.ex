defmodule GSMLG.AdminWeb.GithubLive.Index do
  require Logger

  use GSMLG.AdminWeb, :live_view

  alias GSMLG.GitHub

  @gh_user "gsmlg"
  @gh_orgs [
    "gsmlg-dev",
    "duskmoon-dev",
    "Gao-OS",
    "zdnsweb"
    # "gsmlgorg"
    # "gsmlg-app",
    # "zdnscloud",
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Github Management")
    |> assign_repos()
  end

  @impl Phoenix.LiveView
  def handle_event("delete", _params, socket) do
    {:noreply, socket}
  end

  defp assign_repos(socket) do
    socket
    |> assign_async(:repos, fn ->
      case GitHub.fetch_repos_cache(@gh_user, is_user: true) do
        {:ok, repos} ->
          key = "stargazers_count"
          repos = repos |> Enum.sort(&(&1[key] > &2[key]))
          {:ok, %{repos: repos}}

        {:error, _} ->
          {:ok, %{repos: []}}
      end
    end)
    |> assign_async(:org_repos, fn ->
      org_repos =
        @gh_orgs
        |> Enum.map(fn org ->
          case GitHub.fetch_repos_cache(org, is_user: false, ttl: 60) do
            {:ok, repos} ->
              key = "stargazers_count"
              repos = repos |> Enum.sort(&(&1[key] > &2[key]))
              {org, repos}

            {:error, _} ->
              {org, []}
          end
        end)

      {:ok, %{org_repos: org_repos}}
    end)
  end
end
