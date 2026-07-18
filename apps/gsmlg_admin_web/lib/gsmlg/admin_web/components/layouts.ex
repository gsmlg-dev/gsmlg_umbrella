defmodule GSMLG.AdminWeb.Layouts do
  use GSMLG.AdminWeb, :html

  # Phoenix 1.8: The file name becomes the function name
  # root.html.heex -> root/1 function
  # app.html.heex -> app/1 function
  # auth.html.heex -> auth/1 function

  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :page_title, :string, default: nil, doc: "the page title"
  attr :active_menu, :string, default: nil, doc: "the active admin menu id"
  attr :current_path, :string, default: nil, doc: "the current request path"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex h-dvh min-h-0 flex-col overflow-hidden">
      <.local_app_bar page_title={@page_title} />

      <.dm_flash_group flash={@flash} />

      <div class="flex flex-1 w-full min-h-0 bg-surface text-on-surface">
        <GSMLG.AdminWeb.Components.AdminNavigation.left_menu
          active_menu={@active_menu}
          current_path={@current_path}
        />
        <main class="flex-1 min-w-0 bg-surface text-on-surface overflow-auto">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>
    """
  end

  @doc """
  Renders your auth layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.auth flash={@flash}>
        <h1>Content</h1>
      </Layouts.auth>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def auth(assigns) do
    ~H"""
    <.dm_flash_group flash={@flash} />

    <main class="flex flex-1 w-full min-h-screen relative overflow-hidden bg-base-200">
      <%!-- Scan-line sweep effect --%>
      <div
        class="auth-scan-line absolute inset-x-0 h-px pointer-events-none z-20"
        style="background: linear-gradient(90deg, transparent, color-mix(in oklch, var(--color-primary) 25%, transparent), transparent);"
        aria-hidden="true"
      >
      </div>

      <%!-- LEFT PANEL — branding & decoration --%>
      <aside class="hidden lg:flex flex-col justify-between w-5/12 xl:w-2/5 relative overflow-hidden border-r border-base-300 px-14 py-12">
        <%!-- Grid background --%>
        <div class="auth-grid-bg absolute inset-0 opacity-40" aria-hidden="true"></div>

        <%!-- Concentric ring decoration (center of panel) --%>
        <div
          class="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 pointer-events-none"
          aria-hidden="true"
        >
          <div
            class="auth-ring-pulse w-80 h-80 rounded-full border"
            style="border-color: color-mix(in oklch, var(--color-primary) 15%, transparent);"
          >
          </div>
          <div
            class="auth-ring-pulse absolute inset-0 w-80 h-80 rounded-full border"
            style="border-color: color-mix(in oklch, var(--color-primary) 10%, transparent); animation-delay: 0.8s;"
          >
          </div>
          <div
            class="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 w-40 h-40 rounded-full border"
            style="border-color: color-mix(in oklch, var(--color-primary) 20%, transparent);"
          >
          </div>
          <div
            class="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 w-16 h-16 rounded-full"
            style="background: radial-gradient(circle, color-mix(in oklch, var(--color-primary) 18%, transparent), transparent);"
          >
          </div>
        </div>

        <%!-- Top logo mark --%>
        <div class="relative z-10 auth-enter-1">
          <span class="font-mono text-xs font-bold tracking-[0.3em] uppercase text-primary opacity-80">
            GSMLG · BITW
          </span>
        </div>

        <%!-- Center heading --%>
        <div class="relative z-10 space-y-5 auth-enter-2">
          <p class="font-mono text-[10px] tracking-[0.4em] uppercase text-primary opacity-50">
            ⬡ ADMIN TERMINAL
          </p>
          <h1
            class="font-mono text-5xl font-bold leading-none tracking-tight text-base-content auth-cursor"
            style="text-shadow: 0 0 40px color-mix(in oklch, var(--color-primary) 20%, transparent);"
          >
            SYSTEM<br /><span class="text-primary">ACCESS</span>
          </h1>
          <p class="font-mono text-xs text-base-content opacity-30 leading-relaxed">
            Authorized personnel only.<br />All sessions are monitored.
          </p>
          <div class="flex items-center gap-3 pt-1">
            <div class="w-10 h-px bg-primary opacity-40"></div>
            <div class="w-2 h-2 rounded-full bg-primary opacity-40"></div>
            <div class="w-2 h-px bg-primary opacity-20"></div>
          </div>
        </div>

        <%!-- Bottom version tag --%>
        <div class="relative z-10 font-mono text-[10px] text-base-content opacity-20 tracking-widest auth-enter-3">
          v9 · SECURED · GSMLG
        </div>
      </aside>

      <%!-- RIGHT PANEL — form --%>
      <div class="flex flex-1 justify-center items-center p-8 lg:p-16">
        <div class="auth-enter-3 w-full max-w-sm">
          <div class="auth-card-border pl-8 py-2">
            {render_slot(@inner_block)}
          </div>
        </div>
      </div>
    </main>
    """
  end
end
