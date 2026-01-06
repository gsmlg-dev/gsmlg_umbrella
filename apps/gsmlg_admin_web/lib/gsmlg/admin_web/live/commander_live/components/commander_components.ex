defmodule GSMLG.AdminWeb.CommanderLive.Components do
  @moduledoc """
  Shared components for the Commander Management LiveViews.

  Contains reusable UI components like badges, cards, and status indicators.
  """

  use Phoenix.Component
  import Phoenix.HTML

  @doc """
  Renders a status badge for commander status.
  """
  attr :status, :atom, required: true
  attr :size, :string, default: "normal"

  def status_badge(assigns) do
    {bg_color, text_color, label} =
      case assigns.status do
        :running ->
          {"bg-green-100 dark:bg-green-900", "text-green-800 dark:text-green-200", "Active"}

        :attached ->
          {"bg-green-100 dark:bg-green-900", "text-green-800 dark:text-green-200", "Attached"}

        :detached ->
          {"bg-yellow-100 dark:bg-yellow-900", "text-yellow-800 dark:text-yellow-200", "Detached"}

        :initializing ->
          {"bg-blue-100 dark:bg-blue-900", "text-blue-800 dark:text-blue-200", "Pending"}

        :closing ->
          {"bg-red-100 dark:bg-red-900", "text-red-800 dark:text-red-200", "Closing"}

        :closed ->
          {"bg-gray-100 dark:bg-gray-700", "text-gray-800 dark:text-gray-200", "Closed"}

        # Token statuses
        :active ->
          {"bg-green-100 dark:bg-green-900", "text-green-800 dark:text-green-200", "Active"}

        :unused ->
          {"bg-yellow-100 dark:bg-yellow-900", "text-yellow-800 dark:text-yellow-200", "Unused"}

        :expired ->
          {"bg-red-100 dark:bg-red-900", "text-red-800 dark:text-red-200", "Expired"}

        :revoked ->
          {"bg-gray-100 dark:bg-gray-700", "text-gray-500 dark:text-gray-400", "Revoked"}

        _ ->
          {"bg-gray-100 dark:bg-gray-700", "text-gray-800 dark:text-gray-200",
           to_string(assigns.status)}
      end

    size_class =
      case assigns.size do
        "small" -> "px-2 py-0.5 text-xs"
        "large" -> "px-4 py-1 text-sm"
        _ -> "px-2.5 py-0.5 text-xs"
      end

    assigns =
      assigns
      |> assign(:bg_color, bg_color)
      |> assign(:text_color, text_color)
      |> assign(:label, label)
      |> assign(:size_class, size_class)

    ~H"""
    <span class={"inline-flex items-center rounded-full font-medium #{@size_class} #{@bg_color} #{@text_color}"}>
      <%= @label %>
    </span>
    """
  end

  @doc """
  Renders a capability badge.
  """
  attr :capability, :atom, required: true
  attr :enabled, :boolean, default: true

  def capability_badge(assigns) do
    {icon, label} =
      case assigns.capability do
        :shell -> {"terminal", "Shell"}
        :files -> {"folder", "Files"}
        :processes -> {"cpu", "Processes"}
        :system_info -> {"info", "System"}
        :logs -> {"document", "Logs"}
        :metrics -> {"chart", "Metrics"}
        :services -> {"cog", "Services"}
        _ -> {"bolt", to_string(assigns.capability)}
      end

    assigns = assign(assigns, icon: icon, label: label)

    ~H"""
    <span
      class={"inline-flex items-center px-2 py-1 rounded text-xs font-medium " <>
        if @enabled do
          "bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200"
        else
          "bg-gray-100 dark:bg-gray-700 text-gray-500 dark:text-gray-400"
        end}
      title={@label}
    >
      <.capability_icon name={@icon} class="w-3 h-3 mr-1" />
      <%= @label %>
    </span>
    """
  end

  @doc """
  Renders a tag list.
  """
  attr :tags, :list, required: true
  attr :max, :integer, default: nil

  def tag_list(assigns) do
    tags =
      if assigns.max do
        Enum.take(assigns.tags, assigns.max)
      else
        assigns.tags
      end

    remaining = length(assigns.tags) - length(tags)
    assigns = assign(assigns, displayed_tags: tags, remaining: remaining)

    ~H"""
    <div class="flex flex-wrap gap-1">
      <%= for tag <- @displayed_tags do %>
        <span class="px-2 py-0.5 bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300 text-xs rounded">
          <%= tag %>
        </span>
      <% end %>
      <%= if @remaining > 0 do %>
        <span class="px-2 py-0.5 text-gray-500 dark:text-gray-400 text-xs">
          +<%= @remaining %> more
        </span>
      <% end %>
      <%= if @tags == [] do %>
        <span class="text-gray-400 dark:text-gray-500 text-xs">-</span>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a stats card.
  """
  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :subtitle, :string, default: nil
  attr :color, :string, default: "blue"
  attr :icon, :string, default: nil

  def stats_card(assigns) do
    color_classes = %{
      "blue" => "bg-blue-500",
      "green" => "bg-green-500",
      "yellow" => "bg-yellow-500",
      "red" => "bg-red-500",
      "purple" => "bg-purple-500",
      "gray" => "bg-gray-500"
    }

    color_class = Map.get(color_classes, assigns.color, "bg-blue-500")
    assigns = assign(assigns, :color_class, color_class)

    ~H"""
    <div class="bg-white dark:bg-gray-800 rounded-lg shadow-md p-6">
      <div class="flex items-center">
        <%= if @icon do %>
          <div class={"flex-shrink-0 p-3 rounded-lg #{@color_class}"}>
            <.stats_icon name={@icon} class="w-6 h-6 text-white" />
          </div>
        <% end %>
        <div class={if @icon, do: "ml-4", else: ""}>
          <p class="text-sm font-medium text-gray-500 dark:text-gray-400"><%= @title %></p>
          <p class="text-2xl font-bold text-gray-900 dark:text-white"><%= @value %></p>
          <%= if @subtitle do %>
            <p class="text-xs text-gray-500 dark:text-gray-400 mt-1"><%= @subtitle %></p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a commander row for list views.
  """
  attr :commander, :map, required: true
  attr :selected, :boolean, default: false

  slot :actions

  def commander_row(assigns) do
    ~H"""
    <tr class="hover:bg-gray-50 dark:hover:bg-gray-700">
      <td class="px-6 py-4 whitespace-nowrap">
        <div class="flex items-center">
          <div class={"w-2 h-2 rounded-full mr-3 " <>
            case @commander.status do
              s when s in [:running, :attached] -> "bg-green-500"
              :detached -> "bg-yellow-500"
              :initializing -> "bg-blue-500"
              _ -> "bg-gray-400"
            end}>
          </div>
          <div>
            <div class="text-sm font-medium text-gray-900 dark:text-white">
              <%= @commander.hostname %>
            </div>
            <div class="text-xs text-gray-500 dark:text-gray-400">
              <%= @commander.id %>
            </div>
          </div>
        </div>
      </td>
      <td class="px-6 py-4 whitespace-nowrap">
        <.status_badge status={@commander.status} />
      </td>
      <td class="px-6 py-4">
        <.tag_list tags={@commander.tags} max={3} />
      </td>
      <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500 dark:text-gray-400">
        <%= format_time_ago(@commander.connected_at) %>
      </td>
      <td class="px-6 py-4 whitespace-nowrap text-sm">
        <%= render_slot(@actions) %>
      </td>
    </tr>
    """
  end

  @doc """
  Renders an empty state placeholder.
  """
  attr :title, :string, default: "No data"
  attr :description, :string, default: nil
  attr :icon, :string, default: "inbox"

  slot :actions

  def empty_state(assigns) do
    ~H"""
    <div class="text-center py-12">
      <.empty_icon name={@icon} class="mx-auto h-12 w-12 text-gray-400" />
      <h3 class="mt-2 text-lg font-medium text-gray-900 dark:text-white"><%= @title %></h3>
      <%= if @description do %>
        <p class="mt-1 text-gray-500 dark:text-gray-400"><%= @description %></p>
      <% end %>
      <%= if @actions != [] do %>
        <div class="mt-6">
          <%= render_slot(@actions) %>
        </div>
      <% end %>
    </div>
    """
  end

  # Icon Components

  defp capability_icon(%{name: "terminal"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 9l3 3-3 3m5 0h3M5 20h14a2 2 0 002-2V6a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z" />
    </svg>
    """
  end

  defp capability_icon(%{name: "folder"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z" />
    </svg>
    """
  end

  defp capability_icon(%{name: "cpu"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 3v2m6-2v2M9 19v2m6-2v2M5 9H3m2 6H3m18-6h-2m2 6h-2M7 19h10a2 2 0 002-2V7a2 2 0 00-2-2H7a2 2 0 00-2 2v10a2 2 0 002 2zM9 9h6v6H9V9z" />
    </svg>
    """
  end

  defp capability_icon(%{name: "info"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
    </svg>
    """
  end

  defp capability_icon(%{name: "document"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" />
    </svg>
    """
  end

  defp capability_icon(%{name: "chart"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z" />
    </svg>
    """
  end

  defp capability_icon(%{name: "cog"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z" />
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
    </svg>
    """
  end

  defp capability_icon(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z" />
    </svg>
    """
  end

  defp stats_icon(%{name: "server"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 12h14M5 12a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v4a2 2 0 01-2 2M5 12a2 2 0 00-2 2v4a2 2 0 002 2h14a2 2 0 002-2v-4a2 2 0 00-2-2m-2-4h.01M17 16h.01" />
    </svg>
    """
  end

  defp stats_icon(%{name: "signal"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9.663 17h4.673M12 3v1m6.364 1.636l-.707.707M21 12h-1M4 12H3m3.343-5.657l-.707-.707m2.828 9.9a5 5 0 117.072 0l-.548.547A3.374 3.374 0 0014 18.469V19a2 2 0 11-4 0v-.531c0-.895-.356-1.754-.988-2.386l-.548-.547z" />
    </svg>
    """
  end

  defp stats_icon(%{name: "key"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z" />
    </svg>
    """
  end

  defp stats_icon(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z" />
    </svg>
    """
  end

  defp empty_icon(%{name: "inbox"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20 13V6a2 2 0 00-2-2H6a2 2 0 00-2 2v7m16 0v5a2 2 0 01-2 2H6a2 2 0 01-2-2v-5m16 0h-2.586a1 1 0 00-.707.293l-2.414 2.414a1 1 0 01-.707.293h-3.172a1 1 0 01-.707-.293l-2.414-2.414A1 1 0 006.586 13H4" />
    </svg>
    """
  end

  defp empty_icon(%{name: "server"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 12h14M5 12a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v4a2 2 0 01-2 2M5 12a2 2 0 00-2 2v4a2 2 0 002 2h14a2 2 0 002-2v-4a2 2 0 00-2-2m-2-4h.01M17 16h.01" />
    </svg>
    """
  end

  defp empty_icon(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9.172 16.172a4 4 0 015.656 0M9 10h.01M15 10h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
    </svg>
    """
  end

  # Helper Functions

  defp format_time_ago(nil), do: "-"

  defp format_time_ago(ts) when is_integer(ts) do
    DateTime.from_unix!(div(ts, 1000))
    |> do_format_time_ago()
  end

  defp format_time_ago(%DateTime{} = dt), do: do_format_time_ago(dt)
  defp format_time_ago(_), do: "-"

  defp do_format_time_ago(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "Just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86400)}d ago"
      true -> Calendar.strftime(datetime, "%b %d")
    end
  end
end
