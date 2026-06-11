# Admin Global Left Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build one persistent three-level admin left menu and migrate authenticated admin pages to `Layouts.app`.

**Architecture:** Add a plain Elixir menu data module and a Phoenix functional component renderer. `Layouts.app` becomes the single authenticated shell and delegates navigation rendering to the component while leaving the existing appbar unchanged.

**Tech Stack:** Elixir 1.18, Phoenix 1.8, Phoenix LiveView, HEEX function components, Phoenix DuskMoon `dm_left_menu`.

---

### Task 1: Menu Data Module

**Files:**
- Create: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/admin_menu.ex`
- Test: `apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs`

- [ ] **Step 1: Write failing tests**

Create `GSMLG.AdminWeb.AdminMenuTest` with tests that assert:

```elixir
assert ["Dashboard", "Content", "Cloud", "Service"] =
         GSMLG.AdminWeb.AdminMenu.sections() |> Enum.map(& &1.title)

assert %{id: "lightsail_instance", disabled: true, path: nil} =
         GSMLG.AdminWeb.AdminMenu.find_item!("lightsail_instance")

assert GSMLG.AdminWeb.AdminMenu.group_open?(
         GSMLG.AdminWeb.AdminMenu.find_group!("pki"),
         "pki_ca_list"
       )

refute GSMLG.AdminWeb.AdminMenu.group_open?(
         GSMLG.AdminWeb.AdminMenu.find_group!("aws"),
         "pki_ca_list"
       )

assert GSMLG.AdminWeb.AdminMenu.active_id(nil, "/aws/dynamo_db") == "dynamo_db"
assert GSMLG.AdminWeb.AdminMenu.active_id("pki_ca_list", "/aws/dynamo_db") == "pki_ca_list"
```

- [ ] **Step 2: Run red test**

Run: `mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs`

Expected: compile failure because `GSMLG.AdminWeb.AdminMenu` does not exist.

- [ ] **Step 3: Implement menu data**

Create `GSMLG.AdminWeb.AdminMenu` with:

```elixir
def sections, do: @sections
def find_item!(id), do: Enum.find(flat_items(), &(&1.id == id)) || raise ArgumentError
def find_group!(id), do: Enum.find(flat_groups(), &(&1.id == id)) || raise ArgumentError
def group_open?(group, active_menu), do: Enum.any?(group.items, &active?(&1, active_menu))
def active?(item, active_menu), do: is_binary(active_menu) and active_menu != "" and item.id == active_menu
def active_id(active_menu, path), do: active_menu_if_present_or_item_id_for_path(active_menu, path)
def enabled_items, do: Enum.reject(flat_items(), &Map.get(&1, :disabled, false))
```

Use the approved `Section -> Group -> Item` tree from the design spec.

- [ ] **Step 4: Run green test**

Run: `mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs`

Expected: tests pass.

### Task 2: Navigation Component

**Files:**
- Create: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/components/admin_navigation.ex`
- Test: `apps/gsmlg_admin_web/test/gsmlg/admin_web/components/admin_navigation_test.exs`

- [ ] **Step 1: Write failing component tests**

Create `GSMLG.AdminWeb.Components.AdminNavigationTest` with `Phoenix.LiveViewTest.render_component/2` tests that assert:

```elixir
html = render_component(&GSMLG.AdminWeb.Components.AdminNavigation.left_menu/1,
  active_menu: "pki_ca_list"
)

assert html =~ ~s(aria-label="Admin navigation")
assert html =~ "PKI"
assert html =~ "CA List"
assert html =~ ~s(data-menu-group="pki")
assert html =~ ~s(data-menu-group="pki" open)
refute html =~ ~s(data-menu-group="aws" open)
assert html =~ ~s(aria-current="page")
```

Add a disabled item assertion:

```elixir
html = render_component(&GSMLG.AdminWeb.Components.AdminNavigation.left_menu/1,
  active_menu: "dynamo_db"
)

assert html =~ "Lightsail: Instance"
assert html =~ ~s(aria-disabled="true")
refute html =~ ~s(href="/aws/lightsail")
```

- [ ] **Step 2: Run red test**

Run: `mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/components/admin_navigation_test.exs`

Expected: compile failure because `AdminNavigation` does not exist.

- [ ] **Step 3: Implement component**

Create `GSMLG.AdminWeb.Components.AdminNavigation` with:

```elixir
use GSMLG.AdminWeb, :html

alias GSMLG.AdminWeb.AdminMenu

attr :active_menu, :string, default: nil
attr :current_path, :string, default: nil
attr :class, :any, default: nil

def left_menu(assigns) do
  assigns =
    assigns
    |> assign(:sections, AdminMenu.sections())
    |> assign(:resolved_active_menu, AdminMenu.active_id(assigns[:active_menu], assigns[:current_path]))

  ~H"""
  <aside class={["admin-left-menu bg-secondary text-secondary-content w-72 shrink-0 border-r border-outline-variant", @class]}>
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
```

- [ ] **Step 4: Run green test**

Run: `mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/components/admin_navigation_test.exs`

Expected: tests pass.

### Task 3: Single Authenticated Layout

**Files:**
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/components/layouts.ex`

- [ ] **Step 1: Write layout assertion in component test**

Extend `AdminNavigationTest` with a render test for `Layouts.app`:

```elixir
html =
  render_component(&GSMLG.AdminWeb.Layouts.app/1,
    flash: %{},
    page_title: "Users",
    active_menu: "user_list",
    inner_block: [%{__slot__: :inner_block, inner_block: fn _, _ -> "PAGE BODY" end}]
  )

assert html =~ "PAGE BODY"
assert html =~ ~s(aria-label="Admin navigation")
assert html =~ ~s(data-menu-group="users" open)
```

- [ ] **Step 2: Run red test**

Run: `mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/components/admin_navigation_test.exs`

Expected: failure because `Layouts.app` does not yet render the new left menu or accept `active_menu`.

- [ ] **Step 3: Update layout**

Modify `Layouts.app` to:

- accept `:page_title` and `:active_menu`
- accept optional `:current_path`
- keep `<.local_app_bar page_title={@page_title} />`
- render `<GSMLG.AdminWeb.Components.AdminNavigation.left_menu active_menu={@active_menu} current_path={@current_path} />`
- wrap content in `<main class="flex-1 min-w-0 bg-surface text-on-surface overflow-auto">`
- keep `Layouts.auth`
- remove `Layouts.user`, `Layouts.aws`, `Layouts.storage`, and `Layouts.caddy`

- [ ] **Step 4: Run green test**

Run: `mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/components/admin_navigation_test.exs`

Expected: tests pass.

### Task 4: Template And LiveView Migration

**Files:**
- Modify all admin templates and render functions that still reference `Layouts.user`, `Layouts.aws`, `Layouts.storage`, or `Layouts.caddy`
- Modify PKI templates that use `Layouts.app` without `active_menu`
- Modify Commander render functions to wrap content in `Layouts.app`

- [ ] **Step 1: Search remaining wrappers**

Run: `rg -n "Layouts\\.(user|aws|storage|caddy)|PkiLeftMenu|<Layouts\\.app flash=\\{@flash\\}(?![^>]*active_menu)" apps/gsmlg_admin_web/lib`

Expected before migration: references remain.

- [ ] **Step 2: Migrate wrappers**

Replace old wrappers with:

```heex
<Layouts.app flash={@flash} page_title={@page_title} active_menu={@active_menu}>
```

For static controller templates or pages without `@active_menu`, pass the literal active id:

```heex
<Layouts.app flash={@flash} page_title={@page_title} active_menu="admin_home">
```

Commander render functions should wrap their existing root content:

```heex
<Layouts.app flash={@flash} page_title={@page_title} active_menu="commander_dashboard">
  ...existing content...
</Layouts.app>
```

- [ ] **Step 3: Remove embedded PKI menu usage**

Delete direct `<PkiLeftMenu.pki_left_menu ... />` calls from PKI templates. Keep the PKI component file only if other code still references it; otherwise delete it after `rg "PkiLeftMenu"` returns no references.

- [ ] **Step 4: Verify no old wrappers remain**

Run: `rg -n "Layouts\\.(user|aws|storage|caddy)|PkiLeftMenu" apps/gsmlg_admin_web/lib`

Expected: no matches.

### Task 5: Verification

**Files:**
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/admin_menu.ex`
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/components/admin_navigation.ex`
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/components/layouts.ex`
- migrated admin `.html.heex` templates and inline LiveView render functions
- `docs/superpowers/plans/2026-06-11-admin-global-left-menu.md`

- [ ] **Step 1: Run targeted tests**

Run:

```bash
mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/components/admin_navigation_test.exs
```

Expected: pass.

- [ ] **Step 2: Run broader admin compile check**

Run: `mix compile --warnings-as-errors`

Expected: pass. If it fails because the local DB is missing tables during application start, record the exact failure and run the narrow compile/test checks that do not start the full app.

- [ ] **Step 3: Format**

Run: `mix format`

Expected: no formatting errors.

- [ ] **Step 4: Inspect changed files**

Run: `git diff -- apps/gsmlg_admin_web docs/superpowers/plans/2026-06-11-admin-global-left-menu.md`

Expected: only planned navigation, layout, and template changes.
