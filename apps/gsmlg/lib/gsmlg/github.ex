defmodule GSMLG.GitHub do
  use HTTPoison.Base

  defmacro process_result(result) do
    quote do
      case unquote(result) do
        {:ok,
         %HTTPoison.Response{
           body: data,
           status_code: status_code,
           request: %HTTPoison.Request{url: request_url}
         }}
        when status_code >= 200 and status_code < 300 ->
          IO.inspect({"Access Success", status_code, request_url})
          {:ok, data}

        {:ok,
         %HTTPoison.Response{
           body: data,
           status_code: 401,
           request: %HTTPoison.Request{url: request_url}
         }} ->
          IO.inspect({"Unauthorized Error", 401, request_url})
          {:error, data}

        {:ok,
         %HTTPoison.Response{
           body: body,
           status_code: status_code,
           request: %HTTPoison.Request{url: request_url}
         }}
        when status_code >= 400 and status_code < 500 ->
          IO.inspect({"Client Error", status_code, request_url, body})
          {:error, body}

        {:ok,
         %HTTPoison.Response{
           body: body,
           status_code: status_code,
           request: %HTTPoison.Request{url: request_url}
         }}
        when status_code >= 500 ->
          IO.inspect({"Server Error", status_code, request_url, body})
          {:error, body}

        {:error, %HTTPoison.Error{reason: reason} = error} ->
          IO.inspect({"HTTPoison.Error", error})
          {:error, reason}
      end
    end
  end

  def process_request_url(url) do
    "https://api.github.com" <> url
  end

  def process_request_headers(headers) do
    case System.fetch_env("GITHUB_TOKEN") do
      {:ok, token} ->
        [{"Authorization", "Bearer #{token}"} | headers]

      :error ->
        headers
    end
  end

  def process_request_options(options) do
    # timeout: 30_000, recv_timeout: 120_000
    options
    |> Keyword.put(:timeout, 30_000)
    |> Keyword.put(:recv_timeout, 120_000)
  end

  def process_response_body(body) do
    case Jason.decode(body, [{:keys, :atoms}]) do
      {:ok, resp} -> resp
      {:error, _} -> body
    end
  end

  def fetch_repos() do
    case get("/orgs/gsmlg-dev/repos") |> process_result() do
      {:ok, data} ->
        data

      {:error, _} ->
        [
          %{
            name: "Foundation",
            full_name: "gsmlg-dev/Foundation",
            stargazers_count: 50,
            updated_at: "",
            description: "",
            has_pages: false,
            owner: %{
              login: "gsmlg-dev"
            }
          }
        ]
    end
  end

  def fetch_user_repos(name, opts \\ []) do
    type = Keyword.get(opts, :org, false)
    p = if(type, do: "orgs", else: "users")

    case get("/#{p}/#{name}/repos") |> process_result() do
      {:ok, data} ->
        data

      {:error, _} ->
        []
    end
  end

  def user_repos(name, opts \\ []) do
    GSMLG.SimpleCache.get(__MODULE__, :fetch_user_repos, [name, opts], ttl: 3600)
  end

  @doc """
  Fetch the list of repositories from GitHub.

  Repo

      {
        "id": 654506201,
        "node_id": "R_kgDOJwL42Q",
        "name": "mason-bricks",
        "full_name": "gsmlg-dev/mason-bricks",
        "private": false,
        "owner": {
          "login": "gsmlg-dev",
          "id": 65638344,
          "node_id": "MDEyOk9yZ2FuaXphdGlvbjY1NjM4MzQ0",
          "avatar_url": "https://avatars.githubusercontent.com/u/65638344?v=4",
          "gravatar_id": "",
          "url": "https://api.github.com/users/gsmlg-dev",
          "html_url": "https://github.com/gsmlg-dev",
          "followers_url": "https://api.github.com/users/gsmlg-dev/followers",
          "following_url": "https://api.github.com/users/gsmlg-dev/following{/other_user}",
          "gists_url": "https://api.github.com/users/gsmlg-dev/gists{/gist_id}",
          "starred_url": "https://api.github.com/users/gsmlg-dev/starred{/owner}{/repo}",
          "subscriptions_url": "https://api.github.com/users/gsmlg-dev/subscriptions",
          "organizations_url": "https://api.github.com/users/gsmlg-dev/orgs",
          "repos_url": "https://api.github.com/users/gsmlg-dev/repos",
          "events_url": "https://api.github.com/users/gsmlg-dev/events{/privacy}",
          "received_events_url": "https://api.github.com/users/gsmlg-dev/received_events",
          "type": "Organization",
          "site_admin": false
        },
        "html_url": "https://github.com/gsmlg-dev/mason-bricks",
        "description": null,
        "fork": false,
        "url": "https://api.github.com/repos/gsmlg-dev/mason-bricks",
        "forks_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/forks",
        "keys_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/keys{/key_id}",
        "collaborators_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/collaborators{/collaborator}",
        "teams_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/teams",
        "hooks_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/hooks",
        "issue_events_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/issues/events{/number}",
        "events_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/events",
        "assignees_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/assignees{/user}",
        "branches_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/branches{/branch}",
        "tags_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/tags",
        "blobs_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/git/blobs{/sha}",
        "git_tags_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/git/tags{/sha}",
        "git_refs_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/git/refs{/sha}",
        "trees_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/git/trees{/sha}",
        "statuses_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/statuses/{sha}",
        "languages_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/languages",
        "stargazers_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/stargazers",
        "contributors_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/contributors",
        "subscribers_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/subscribers",
        "subscription_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/subscription",
        "commits_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/commits{/sha}",
        "git_commits_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/git/commits{/sha}",
        "comments_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/comments{/number}",
        "issue_comment_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/issues/comments{/number}",
        "contents_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/contents/{+path}",
        "compare_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/compare/{base}...{head}",
        "merges_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/merges",
        "archive_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/{archive_format}{/ref}",
        "downloads_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/downloads",
        "issues_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/issues{/number}",
        "pulls_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/pulls{/number}",
        "milestones_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/milestones{/number}",
        "notifications_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/notifications{?since,all,participating}",
        "labels_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/labels{/name}",
        "releases_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/releases{/id}",
        "deployments_url": "https://api.github.com/repos/gsmlg-dev/mason-bricks/deployments",
        "created_at": "2023-06-16T09:21:45Z",
        "updated_at": "2023-07-04T03:54:29Z",
        "pushed_at": "2023-08-08T09:35:43Z",
        "git_url": "git://github.com/gsmlg-dev/mason-bricks.git",
        "ssh_url": "git@github.com:gsmlg-dev/mason-bricks.git",
        "clone_url": "https://github.com/gsmlg-dev/mason-bricks.git",
        "svn_url": "https://github.com/gsmlg-dev/mason-bricks",
        "homepage": "",
        "size": 35,
        "stargazers_count": 0,
        "watchers_count": 0,
        "language": "Dart",
        "has_issues": true,
        "has_projects": false,
        "has_downloads": true,
        "has_wiki": false,
        "has_pages": false,
        "has_discussions": false,
        "forks_count": 0,
        "mirror_url": null,
        "archived": false,
        "disabled": false,
        "open_issues_count": 0,
        "license": {
          "key": "mit",
          "name": "MIT License",
          "spdx_id": "MIT",
          "url": "https://api.github.com/licenses/mit",
          "node_id": "MDc6TGljZW5zZTEz"
        },
        "allow_forking": true,
        "is_template": false,
        "web_commit_signoff_required": false,
        "topics": [

        ],
        "visibility": "public",
        "forks": 0,
        "open_issues": 0,
        "watchers": 0,
        "default_branch": "main",
        "permissions": {
          "admin": false,
          "maintain": false,
          "push": false,
          "triage": false,
          "pull": true
        }
      }
  """
  @spec repos :: List.t()
  def repos() do
    GSMLG.SimpleCache.get(__MODULE__, :fetch_repos, [], ttl: 3600)
  end
end
