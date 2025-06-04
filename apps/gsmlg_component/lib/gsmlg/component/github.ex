defmodule GSMLG.Component.Github do
  @moduledoc """
  Provides Github components.

  """
  use Phoenix.Component
  use PhoenixDuskmoon.Component

  # alias Phoenix.LiveView.JS
  use Gettext, backend: GSMLGWeb.Gettext

  @doc """
  Renders a github repo card.
  """
  attr(:class, :string, default: nil)
  attr(:repo, :map, default: %{})

  def github_repo_card(assigns) do
    ~H"""
    <div
      class={[
        "flex flex-col h-44 p-4 shadow shadow-base-content rounded-box",
        "transition duration-300 origin-center",
        "hover:shadow-lg hover:scale-105 hover:translate-z-12",
        "bg-primary text-primary-content",
        @class
      ]}
    >
      <div class="flex justify-between">
        <h3 class="font-bold text-xl">
          {@repo["name"]}
        </h3>
        <.dm_link
          class="text-info-content/50 font-light text-lg"
          href={"https://github.com/#{@repo["full_name"]}"}
          target="_blank"
        >
          {dgettext("github", "View Repo")}
        </.dm_link>
      </div>

      <div class="text-medium text-secondary">
        <%= if @repo["has_pages"] do %>
          <.dm_link
            class="text-accent font-light text-lg"
            href={~s[https://#{@repo["owner"]["login"]}.github.io/#{@repo["name"]}]}
            target="_blank"
          >
            {dgettext("github", "GH Page")}
          </.dm_link>
        <% end %>
        <.dm_link
          class="flex items-center gap-2 float-right"
          href={~s[https://github.com/#{@repo["owner"]["login"]}/#{@repo["name"]}/stargazers]}
          target="_blank"
        >
          <label class="flex items-center">
            <.dm_mdi name="star" class="w-5 h-5 inline-block" />
          </label>
          <span>{@repo["stargazers_count"]}</span>
        </.dm_link>
      </div>
      <div class="flex gap-4 text-sm text-neutral-content/60">
        <label class="after:content-[':']">{dgettext("github", "Last updated")}</label>
        <time>{@repo["updated_at"]}</time>
      </div>
      <p class="text-neutral-content text-ellipsis overflow-y-auto">{@repo["description"]}</p>
    </div>
    """
  end

  attr(:repo, :any,
    default: %{},
    doc: """
    repo data

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
  )

  def github_repo_info_card(assigns) do
    ~H"""
    <div class="card card-bordered card-compact bg-neutral text-neutral-content">
      <div class="card-body">
        <div class="card-title">
          <div :if={@repo["private"]} class="badge badge-error tooltip" data-tip="Private">
            <.dm_mdi name="account-key-outline" class="w-5 h-5 text-neutral-content" />
          </div>
          {@repo["name"]}
          <div :if={@repo["language"]} class="badge badge-accent">{@repo["language"]}</div>
        </div>
        <div>
          <.link href={@repo["html_url"] <> "/stargazers"} class="btn btn-xs" target="_blank">
            Star {@repo["stargazers_count"]}
          </.link>
          <.link href={@repo["html_url"] <> "/forks"} class="btn btn-xs" target="_blank">
            Fork {@repo["forks"]}
          </.link>
          <.link href={@repo["html_url"] <> "/issues"} class="btn btn-xs" target="_blank">
            Issue {@repo["open_issues"]}
          </.link>
        </div>
        <p>
          {@repo["description"] || gettext("No description")}
        </p>
        <div class="card-actions justify-end">
          <.link href={@repo["html_url"]} class="btn btn-primary btn-sm" target="_blank">
            Home Page
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
