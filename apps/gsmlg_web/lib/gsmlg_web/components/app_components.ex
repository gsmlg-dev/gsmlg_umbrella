defmodule GSMLGWeb.AppComponents do
  @moduledoc """
  Provides core UI components.

  The components in this module use Tailwind CSS, a utility-first CSS framework.
  See the [Tailwind CSS documentation](https://tailwindcss.com) to learn how to
  customize the generated components in this module.

  Icons are provided by [heroicons](https://heroicons.com), using the
  [heroicons_elixir](https://github.com/mveytsman/heroicons_elixir) project.
  """
  use Phoenix.Component

  # alias Phoenix.LiveView.JS
  # import GSMLGWeb.Gettext

  @doc """
  Renders a header with title.
  """
  attr(:class, :string, default: nil)
  attr(:repo, :map, default: %{})

  def github_repo_card(assigns) do
    ~H"""
    <div class={"flex flex-col w-[calc(33%-2em)] h-44 p-4 shadow dark:shadow-slate-400 #{@class}"}>
      <div class="flex justify-between">
        <h3 class="font-bold text-xl">
          <%= @repo.name %>
        </h3>
        <.link
          class="text-blue-400 font-light text-lg"
          href={"https://github.com/#{@repo.full_name}"}
          target="_blank"
        >LINK</.link>
      </div>

      <div class="text-medium text-cyan-400">
        <%= if @repo.has_pages do %>
        <.link
          class="text-pink-500 font-light text-lg"
          href={"https://#{@repo.owner.login}.github.io/#{@repo.name}"}
          target="_blank"
        >PAGES</.link>
        <% end %>
        <label class="after:content-[':']">Stars</label>
        <time><%= @repo.stargazers_count %></time>
      </div>
      <div class="text-emerald-300">
        <label class="after:content-[':']">Last updated</label>
        <time><%= @repo.updated_at %></time>
      </div>
      <p class="text-gray-400 text-ellipsis overflow-y-auto"><%= @repo.description %></p>
    </div>
    """
  end
end
