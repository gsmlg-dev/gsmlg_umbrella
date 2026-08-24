defmodule GSMLG.AdminWeb.GaoNoteLive.DashboardLive do
  use GSMLG.AdminWeb, :user_live_view

  alias GSMLG.AdminWeb.GaoNoteLive.NotesPath
  alias GSMLG.GaoNote
  alias Phoenix.LiveView.AsyncResult

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "GaoNote Dashboard")
     |> assign(:active_menu, "gao_note_dashboard")
     |> assign(:category_groups, AsyncResult.loading())
     |> assign_async(
       :category_groups,
       fn -> {:ok, %{category_groups: GaoNote.list_category_groups()}} end,
       reset: true
     )}
  end

  attr(:category_groups, :any, required: true)

  def category_groups(assigns) do
    ~H"""
    <div id="gao-note-category-groups">
      <div
        :if={async_failed?(@category_groups)}
        id="gao-note-categories-unavailable"
        class="rounded-xl border border-error/40 bg-error-container p-4 text-sm text-on-error-container"
        role="status"
      >
        Category dashboard is unavailable.
      </div>

      <div
        :if={async_loading?(@category_groups)}
        id="gao-note-categories-loading"
        class="grid gap-3 md:grid-cols-2 xl:grid-cols-3"
        aria-label="Loading GaoNote categories"
      >
        <.dm_skeleton_card :for={index <- 1..3} id={"gao-note-category-skeleton-#{index}"} />
      </div>

      <div
        :if={async_ready?(@category_groups) and async_value(@category_groups) == []}
        id="gao-note-categories-empty"
        class="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-outline-variant bg-surface-container p-4 text-on-surface"
      >
        <p class="text-sm text-on-surface-variant">No Category labels configured.</p>
        <.dm_link
          navigate={~p"/gao_notes/label_settings"}
          class="btn btn-secondary btn-sm"
        >
          Configure Category labels
        </.dm_link>
      </div>

      <div
        :if={async_ready?(@category_groups) and async_value(@category_groups) != []}
        class="grid gap-3 md:grid-cols-2 xl:grid-cols-3"
      >
        <.dm_card
          :for={group <- async_value(@category_groups)}
          id={"gao-note-category-#{group.position}"}
          variant="bordered"
          class="bg-surface-container text-on-surface"
          body_class="grid h-full gap-3"
        >
          <div class="grid gap-1 border-b border-outline-variant pb-3">
            <h2 class="font-mono text-base font-semibold">{group.selector}</h2>
            <p :if={present?(group.description)} class="text-sm text-on-surface-variant">
              {group.description}
            </p>
          </div>

          <p :if={group.values == []} class="text-sm text-on-surface-variant">
            No notes in this category.
          </p>

          <div :if={group.values != []} class="flex flex-wrap gap-2">
            <.dm_chip
              :for={value <- group.values}
              navigate={NotesPath.exact_label(group.key, value.value)}
              color="primary"
              size="sm"
              aria-label={filter_label(group.key, value.value, value.count)}
            >
              {value.value} · {value.count}
            </.dm_chip>
          </div>
        </.dm_card>
      </div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} active_menu={@active_menu}>
      <div class="w-full bg-surface p-4 text-on-surface sm:p-6">
        <div class="mx-auto grid max-w-7xl gap-4">
          <header class="flex flex-wrap items-start justify-between gap-3 rounded-2xl bg-surface-container-low p-4">
            <div class="grid gap-1">
              <div class="flex items-center gap-2">
                <.dm_mdi name="view-dashboard-outline" class="h-6 w-6 text-primary" />
                <h1 class="text-2xl font-semibold">GaoNote Dashboard</h1>
              </div>
              <p class="text-sm text-on-surface-variant">
                Browse active notes through configured label categories.
              </p>
            </div>
            <.dm_link navigate={~p"/gao_notes/label_settings"} class="btn btn-secondary btn-sm">
              <.dm_mdi name="tune-variant" class="h-4 w-4" /> Configure
            </.dm_link>
          </header>

          <.category_groups category_groups={@category_groups} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp async_loading?(%AsyncResult{loading: loading, failed: nil}), do: not is_nil(loading)
  defp async_loading?(_result), do: false

  defp async_failed?(%AsyncResult{failed: failed}), do: not is_nil(failed)
  defp async_failed?(_result), do: false

  defp async_ready?(%AsyncResult{ok?: true, failed: nil, loading: nil}), do: true
  defp async_ready?(_result), do: false

  defp async_value(%AsyncResult{ok?: true, result: result}), do: result
  defp async_value(_result), do: []

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp filter_label(key, value, 1), do: "Filter notes by #{key}=#{value}, 1 active note"

  defp filter_label(key, value, count),
    do: "Filter notes by #{key}=#{value}, #{count} active notes"
end
