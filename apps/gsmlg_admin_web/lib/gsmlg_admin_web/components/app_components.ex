defmodule GSMLGAdminWeb.AppComponents do
  @moduledoc """
  Provides App UI components.
  """
  use Phoenix.Component
  use PhoenixDuskmoon.Component

  alias Phoenix.LiveView.JS
  import GSMLGAdminWeb.Gettext
  import GSMLGAdminWeb.CoreComponents

  @doc """
  Renders flash notices.

  ## Examples

      <.dm_flash kind={:info} flash={@flash} />
      <.dm_flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.dm_flash>
  """
  attr(:id, :string, default: "flash", doc: "the optional id of flash container")
  attr(:flash, :map, default: %{}, doc: "the map of flash messages to display")
  attr(:title, :string, default: nil)
  attr(:kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup")
  attr(:autoshow, :boolean, default: true, doc: "whether to auto show the flash on mount")
  attr(:close, :boolean, default: true, doc: "whether the flash can be closed")
  attr(:rest, :global, doc: "the arbitrary HTML attributes to add to the flash container")

  slot(:inner_block, doc: "the optional inner block that renders the flash message")

  def dm_flash(assigns) do
    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-mounted={@autoshow && JS.show(to: "##{@id}")}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> JS.hide(to: "##{@id}")}
      role="alert"
      class={"hidden w-80 sm:w-96 toast toast-top toast-end z-[1000]"}
      {@rest}
    >
      <div class={["flex flex-col gap-2 relative alert", if(@kind == :info, do: "alert-info"), if(@kind == :error, do: "alert-error")]}>
        <div :if={@title} class="flex items-center gap-1.5 w-full text-xs font-semibold leading-6">
          <.dm_bsi :if={@kind == :info} name="info-circle" class="w-4 h-4" />
          <.dm_bsi :if={@kind == :error} name="exclamation-circle" class="w-4 h-4" />
          <%= @title %>
        </div>
        <div class="w-full text-xs leading-5"><%= msg %></div>
        <button
          :if={@close}
          type="button"
          class="absolute top-2 right-2 btn btn-ghost btn-xs"
          aria-label={gettext("close")}
        >
          <.dm_bsi name="x" class="w-5 h-5 " />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.dm_flash_group flash={@flash} />
  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")

  def dm_flash_group(assigns) do
    ~H"""
    <.dm_flash id="flash-info" kind={:info} title={"Success!"} flash={@flash} />
    <.dm_flash id="flash-error" kind={:error} title={"Error!"} flash={@flash} />
    <.dm_flash
      id="disconnected"
      kind={:error}
      title="We can't find the internet"
      close={false}
      autoshow={false}
      phx-disconnected={show("#disconnected")}
      phx-connected={hide("#disconnected")}
    >
      Attempting to reconnect <.dm_bsi name="arrow-repeat" class="inline ml-1 w-3 h-3 animate-spin" />
    </.dm_flash>
    """
  end

  def local_app_bar(assigns) do
    ~H"""
    <.dm_simple_appbar title={assigns[:page_title]} class="h-14 text-white bg-primary ">
      <:logo>
        <.link navigate={"/"}>
          <logo-gsmlg-dev class="h-12" />
        </.link>
      </:logo>
      <:user_profile>
        <.link href={"/sign_out"} method="DELETE" data-confirm="Really?">Sign Out</.link>
      </:user_profile>
    </.dm_simple_appbar>
    """
  end

  attr(:repo, :any, default: %{},
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

  def github_repo_info(assigns) do
    ~H"""
    <div class="card card-bordered card-compact bg-neutral text-neutral-content">
      <div class="card-body">
        <div class="card-title">
          <%= @repo.name %>
          <div class="badge badge-accent" :if={@repo.language}><%= @repo.language %></div>
        </div>
        <div>
          <.link href={@repo.html_url <> "/stargazers"} class="btn btn-xs" target="_blank">
            Star
            <%= @repo.stargazers_count %>
          </.link>
          <.link href={@repo.html_url <> "/forks"} class="btn btn-xs" target="_blank">
            Fork
            <%= @repo.forks %>
          </.link>
          <.link href={@repo.html_url <> "/issues"} class="btn btn-xs" target="_blank">
            Issue
            <%= @repo.open_issues %>
          </.link>
        </div>
        <p>
          <%= @repo.description || gettext("No description") %>
        </p>
        <div class="card-actions justify-end">
          <.link href={@repo.html_url} class="btn btn-primary btn-sm" target="_blank">Home Page</.link>
        </div>
      </div>
    </div>
    """
  end
end
