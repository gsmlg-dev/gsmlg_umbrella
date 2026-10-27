defmodule GSMLG.AdminWeb.Components.AdminNavigation do
  @moduledoc """
  Global authenticated admin navigation.
  """

  use GSMLG.AdminWeb, :html

  alias GSMLG.AdminWeb.AdminMenu

  attr :id, :string, default: "admin-sidebar"
  attr :collapsible, :boolean, default: true
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
    <.dm_left_menu
      id={@id}
      collapsible={@collapsible}
      storage_key={if @collapsible, do: "gsmlg:admin-sidebar-collapsed"}
      active={@resolved_active_menu || ""}
      size="sm"
      nav_label="Admin navigation"
      class={[
        "admin-left-menu h-full bg-surface-container-low text-on-surface border-r border-outline-variant",
        !@collapsible && "w-72",
        @class
      ]}
    >
      <:menu :for={section <- @sections}>
        <div class="nested-menu-title" data-menu-section={section.id}>{section.title}</div>
        <.dm_left_menu_group
          :for={group <- section.groups}
          id={"#{@id}-#{group.id}"}
          data-menu-group={group.id}
          active={@resolved_active_menu || ""}
          open={AdminMenu.group_open?(group, @resolved_active_menu)}
        >
          <:title>{group.title}</:title>
          <:menu
            :for={item <- group.items}
            id={item.id}
            to={item.path}
            icon={item.icon}
            label={item.label}
            disabled={item[:disabled]}
          >
            {item.label}
          </:menu>
        </.dm_left_menu_group>
      </:menu>
    </.dm_left_menu>
    """
  end
end
