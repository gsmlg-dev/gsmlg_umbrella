defmodule GSMLG.AdminWeb.Components.AdminNavigation do
  @moduledoc """
  Global authenticated admin navigation.
  """

  use GSMLG.AdminWeb, :html

  alias GSMLG.AdminWeb.AdminMenu

  attr :active_menu, :string, default: nil
  attr :current_path, :string, default: nil
  attr :class, :any, default: nil

  def left_menu(assigns) do
    assigns =
      assigns
      |> assign(:sections, AdminMenu.sections())
      |> assign(
        :resolved_active_menu,
        AdminMenu.active_id(assigns[:active_menu], assigns[:current_path])
      )

    ~H"""
    <aside class={[
      "admin-left-menu bg-secondary text-secondary-content w-72 shrink-0 border-r border-outline-variant",
      @class
    ]}>
      <div class="sticky top-0 h-[calc(100vh-3.5rem)] overflow-y-auto p-3">
        <.dm_left_menu active={@resolved_active_menu || ""} size="sm" nav_label="Admin navigation">
          <:title class="px-2 py-3">
            <div class="font-mono text-xs tracking-widest uppercase">GSMLG Admin</div>
          </:title>
          <:menu :for={section <- @sections}>
            <li class="nested-menu-title" data-menu-section={section.id}>{section.title}</li>
            <details
              :for={group <- section.groups}
              data-menu-group={group.id}
              open={AdminMenu.group_open?(group, @resolved_active_menu)}
            >
              <summary>{group.title}</summary>
              <ul role="list">
                <li :for={item <- group.items} class={[item[:disabled] && "disabled"]}>
                  <span
                    :if={item[:disabled]}
                    class="opacity-50 cursor-not-allowed"
                    aria-disabled="true"
                  >
                    {item.label}
                  </span>
                  <.link
                    :if={!item[:disabled]}
                    navigate={item.path}
                    class={[AdminMenu.active?(item, @resolved_active_menu) && "active"]}
                    aria-current={AdminMenu.active?(item, @resolved_active_menu) && "page"}
                  >
                    {item.label}
                  </.link>
                </li>
              </ul>
            </details>
          </:menu>
        </.dm_left_menu>
      </div>
    </aside>
    """
  end
end
