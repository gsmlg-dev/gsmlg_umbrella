defmodule GSMLG.Component.Github do
  @moduledoc """
  Provides Github components.

  """
  use Phoenix.Component
  use PhoenixDuskmoon.Component

  # alias Phoenix.LiveView.JS
  use Gettext, backend: GSMLG.Web.Gettext

  @doc """
  Renders a github repo card.
  """
  attr(:class, :string, default: nil)
  attr(:repo, :map, default: %{})

  def github_repo_card(assigns) do
    ~H"""
    <.dm_card
      class={[
        "transition-all duration-300 hover:-translate-y-1",
        @class
      ]}
      variant="bordered"
      interactive={true}
      body_class="flex flex-col gap-1"
    >
      <:title>
        <div class="flex items-start justify-between gap-2 w-full">
          <.dm_link
            class="font-bold text-sm leading-snug line-clamp-1 hover:text-primary transition-colors duration-150"
            href={"https://github.com/#{@repo["full_name"]}"}
            target="_blank"
          >
            {@repo["name"]}
          </.dm_link>
          <a
            href={~s[https://github.com/#{@repo["owner"]["login"]}/#{@repo["name"]}/stargazers]}
            target="_blank"
            class="flex items-center gap-1 shrink-0 text-xs font-mono text-warning hover:opacity-80"
          >
            <.dm_mdi name="star" class="w-3.5 h-3.5" />
            <span>{@repo["stargazers_count"]}</span>
          </a>
        </div>
      </:title>

      <p class="text-sm text-base-content/55 line-clamp-2 min-h-10">
        {@repo["description"] || ""}
      </p>

      <:action>
        <div class="flex items-center justify-between w-full text-xs text-base-content/40">
          <time class="font-mono tabular-nums">
            {String.slice(@repo["updated_at"] || "", 0, 10)}
          </time>
          <div class="flex items-center gap-2">
            <%= if @repo["has_pages"] do %>
              <.dm_link
                class="text-accent hover:underline"
                href={~s[https://#{@repo["owner"]["login"]}.github.io/#{@repo["name"]}]}
                target="_blank"
              >
                {dgettext("github", "GH Page")}
              </.dm_link>
            <% end %>
            <%= if @repo["language"] do %>
              <.dm_badge variant="ghost" size="xs">{@repo["language"]}</.dm_badge>
            <% end %>
          </div>
        </div>
      </:action>
    </.dm_card>
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
    <.dm_card variant="bordered" body_class="flex flex-col gap-3">
      <:title>
        <div class="flex items-start justify-between gap-2 w-full">
          <div class="flex items-center gap-1.5 min-w-0">
            <.dm_badge :if={@repo["private"]} size="xs" class="badge-error">
              <.dm_mdi name="lock-outline" class="w-3 h-3" /> Private
            </.dm_badge>
            <.link
              href={@repo["html_url"]}
              target="_blank"
              class="font-semibold text-sm leading-snug truncate hover:text-primary transition-colors"
            >
              {@repo["name"]}
            </.link>
          </div>
          <.dm_badge :if={@repo["language"]} variant="ghost" size="xs" class="shrink-0">
            {@repo["language"]}
          </.dm_badge>
        </div>
      </:title>

      <p class="text-sm text-base-content/55 line-clamp-2 min-h-9">
        {@repo["description"] || gettext("No description")}
      </p>

      <:action>
        <div class="flex items-center justify-between w-full">
          <div class="flex items-center gap-3 text-xs text-base-content/50 font-mono">
            <a
              href={@repo["html_url"] <> "/stargazers"}
              target="_blank"
              class="flex items-center gap-1 hover:text-warning transition-colors"
            >
              <.dm_mdi name="star-outline" class="w-3.5 h-3.5" />
              {@repo["stargazers_count"]}
            </a>
            <a
              href={@repo["html_url"] <> "/forks"}
              target="_blank"
              class="flex items-center gap-1 hover:text-info transition-colors"
            >
              <.dm_mdi name="source-fork" class="w-3.5 h-3.5" />
              {@repo["forks"]}
            </a>
            <a
              href={@repo["html_url"] <> "/issues"}
              target="_blank"
              class="flex items-center gap-1 hover:text-error transition-colors"
            >
              <.dm_mdi name="alert-circle-outline" class="w-3.5 h-3.5" />
              {@repo["open_issues"]}
            </a>
          </div>
          <.link href={@repo["html_url"]} target="_blank">
            <.dm_btn variant="ghost" size="xs">
              <.dm_mdi name="github" class="w-3.5 h-3.5" /> View
            </.dm_btn>
          </.link>
        </div>
      </:action>
    </.dm_card>
    """
  end
end
