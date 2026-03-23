defmodule GSMLG.AdminWeb.Layouts do
  use GSMLG.AdminWeb, :html

  # Phoenix 1.8: The file name becomes the function name
  # root.html.heex -> root/1 function
  # app.html.heex -> app/1 function
  # auth.html.heex -> auth/1 function
  # aws.html.heex -> aws/1 function
  # bumblebee.html.heex -> bumblebee/1 function
  # user.html.heex -> user/1 function

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

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <.local_app_bar page_title={assigns[:page_title]} />

    <.dm_flash_group flash={@flash} />

    <main class="flex flex-1 justify-center w-full">
      {render_slot(@inner_block)}
    </main>
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

  @doc """
  Renders your AWS layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.aws flash={@flash}>
        <h1>Content</h1>
      </Layouts.aws>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :page_title, :string, default: nil
  attr :active_menu, :string, default: nil

  slot :inner_block, required: true

  def aws(assigns) do
    ~H"""
    <.local_app_bar page_title={@page_title} />

    <.dm_flash_group flash={@flash} />

    <main class="flex flex-1 w-full">
      <.dm_left_menu>
        <:menu>
          <h2 class="menu-title">DynamoDB</h2>
          <ul>
            <li>
              <.link
                class={if("dynamo_db" == @active_menu, do: "active")}
                navigate={~p"/aws/dynamo_db"}
              >
                DynamoDB
              </.link>
            </li>
          </ul>
        </:menu>
        <:menu>
          <h2 class="menu-title">Route 53</h2>
          <ul>
            <li>
              <.link
                class={if("route53_hosted_zone_list" == @active_menu, do: "active")}
                navigate={~p"/aws/route53/hosted_zones"}
              >
                Hosted Zone List
              </.link>
            </li>
          </ul>
        </:menu>
        <:menu>
          <h2 class="menu-title">S3</h2>
          <ul>
            <li>
              <.link
                class={if("s3_buckets_list" == @active_menu, do: "active")}
                navigate={~p"/aws/s3/buckets"}
              >
                S3 Buckets List
              </.link>
            </li>
          </ul>
        </:menu>
      </.dm_left_menu>
      <div class="flex flex-col flex-auto mx-auto max-w-screen-2xl">
        {render_slot(@inner_block)}
      </div>
    </main>
    """
  end

  @doc """
  Renders your Bumblebee layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.bumblebee flash={@flash}>
        <h1>Content</h1>
      </Layouts.bumblebee>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :page_title, :string, default: nil
  attr :active_menu, :string, default: nil

  slot :inner_block, required: true

  def bumblebee(assigns) do
    ~H"""
    <.local_app_bar page_title={@page_title} />

    <.dm_flash_group flash={@flash} />

    <main class="flex flex-1 w-full">
      <div class="relative">
        <.dm_left_menu class="sticky top-0">
          <:menu>
            <h1 class="menu-title text-primary">Bumblebee</h1>
          </:menu>
          <:menu>
            <h2 class="menu-title">Audio</h2>
            <ul>
              <li>
                <.link
                  class={if("stt_live" == @active_menu, do: "active")}
                  navigate={~p"/bumblebee/stt"}
                >
                  STT
                </.link>
              </li>
            </ul>
          </:menu>
        </.dm_left_menu>
      </div>
      <div class="flex flex-col flex-auto mx-auto max-w-screen-2xl">
        {render_slot(@inner_block)}
      </div>
    </main>
    """
  end

  @doc """
  Renders your Caddy management layout.

  Used for all /caddy/* management pages with a left sidebar
  containing navigation links to each Caddy management section.

  ## Examples

      <Layouts.caddy flash={@flash}>
        <h1>Content</h1>
      </Layouts.caddy>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :page_title, :string, default: nil
  attr :active_menu, :string, default: nil

  slot :inner_block, required: true

  def caddy(assigns) do
    ~H"""
    <.local_app_bar page_title={@page_title} />

    <.dm_flash_group flash={@flash} />

    <main class="flex flex-1 w-full">
      <div class="relative">
        <.dm_left_menu class="sticky top-0">
          <:menu>
            <h1 class="menu-title text-primary">Caddy</h1>
          </:menu>
          <:menu>
            <h2 class="menu-title">Overview</h2>
            <ul>
              <li>
                <.link
                  class={if("caddy_dashboard" == @active_menu, do: "active")}
                  navigate={~p"/caddy"}
                >
                  Dashboard
                </.link>
              </li>
            </ul>
          </:menu>
          <:menu>
            <h2 class="menu-title">Management</h2>
            <ul>
              <li>
                <.link
                  class={if("caddy_config" == @active_menu, do: "active")}
                  navigate={~p"/caddy/config"}
                >
                  Configuration
                </.link>
              </li>
              <li>
                <.link
                  class={if("caddy_server" == @active_menu, do: "active")}
                  navigate={~p"/caddy/server"}
                >
                  Server Control
                </.link>
              </li>
              <li>
                <.link
                  class={if("caddy_runtime" == @active_menu, do: "active")}
                  navigate={~p"/caddy/runtime"}
                >
                  Runtime Config
                </.link>
              </li>
            </ul>
          </:menu>
          <:menu>
            <h2 class="menu-title">Observability</h2>
            <ul>
              <li>
                <.link
                  class={if("caddy_metrics" == @active_menu, do: "active")}
                  navigate={~p"/caddy/metrics"}
                >
                  Metrics
                </.link>
              </li>
              <li>
                <.link
                  class={if("caddy_logs" == @active_menu, do: "active")}
                  navigate={~p"/caddy/logs"}
                >
                  Logs
                </.link>
              </li>
            </ul>
          </:menu>
        </.dm_left_menu>
      </div>
      <div class="flex flex-col flex-auto mx-auto max-w-screen-2xl">
        {render_slot(@inner_block)}
      </div>
    </main>
    """
  end

  @doc """
  Renders your storage management layout.

  ## Examples

      <Layouts.storage flash={@flash}>
        <h1>Content</h1>
      </Layouts.storage>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :page_title, :string, default: nil
  attr :active_menu, :string, default: nil

  slot :inner_block, required: true

  def storage(assigns) do
    ~H"""
    <.local_app_bar page_title={@page_title} />

    <.dm_flash_group flash={@flash} />

    <main class="flex flex-1 w-full">
      <div class="relative">
        <.dm_left_menu class="sticky top-0">
          <:menu>
            <h1 class="menu-title text-primary">Storage</h1>
          </:menu>
          <:menu>
            <h2 class="menu-title">Files</h2>
            <ul>
              <li>
                <.link
                  class={if("storage_files" == @active_menu, do: "active")}
                  navigate={~p"/storage"}
                >
                  File Browser
                </.link>
              </li>
            </ul>
          </:menu>
          <:menu>
            <h2 class="menu-title">Settings</h2>
            <ul>
              <li>
                <.link
                  class={if("storage_config" == @active_menu, do: "active")}
                  navigate={~p"/storage/config"}
                >
                  S3 Configuration
                </.link>
              </li>
            </ul>
          </:menu>
        </.dm_left_menu>
      </div>
      <div class="flex flex-col flex-auto mx-auto max-w-screen-2xl">
        {render_slot(@inner_block)}
      </div>
    </main>
    """
  end

  @doc """
  Renders your user layout.

  ## Examples

      <Layouts.user flash={@flash}>
        <h1>Content</h1>
      </Layouts.user>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :page_title, :string, default: nil
  attr :active_menu, :string, default: nil

  slot :inner_block, required: true

  def user(assigns) do
    ~H"""
    <.local_app_bar page_title={@page_title} />

    <.dm_flash_group flash={@flash} />

    <main class="flex flex-1 w-full">
      <div class="relative">
        <.dm_left_menu class="sticky top-0">
          <:menu>
            <h2 class="menu-title">User Managment</h2>
            <ul>
              <li>
                <.link
                  class={if("user_list" == @active_menu, do: "active")}
                  navigate={~p"/users"}
                >
                  User List
                </.link>
              </li>
              <li>
                <.link
                  class={if("user_token_list" == @active_menu, do: "active")}
                  navigate={~p"/user_tokens"}
                >
                  User Token
                </.link>
              </li>
            </ul>
          </:menu>
          <:menu>
            <h2 class="menu-title">Blog Managment</h2>
            <ul>
              <li>
                <.link
                  class={if("blog_list" == @active_menu, do: "active")}
                  navigate={~p"/blogs"}
                >
                  Blog List
                </.link>
              </li>
              <li>
                <.link
                  class={if("blog_import" == @active_menu, do: "active")}
                  navigate={~p"/blogs/import"}
                >
                  Blog Import
                </.link>
              </li>
            </ul>
          </:menu>
          <:menu>
            <h2 class="menu-title">Web Push</h2>
            <ul>
              <li>
                <.link
                  class={if("web_push" == @active_menu, do: "active")}
                  navigate={~p"/web_push"}
                >
                  Web Push Subscriptions
                </.link>
              </li>
            </ul>
          </:menu>
          <:menu>
            <h2 class="menu-title">API Providers</h2>
            <ul>
              <li>
                <.link
                  class={if("api_providers" == @active_menu, do: "active")}
                  navigate={~p"/api_providers"}
                >
                  Provider List
                </.link>
              </li>
            </ul>
          </:menu>
        </.dm_left_menu>
      </div>
      <div class="flex flex-col flex-auto mx-auto max-w-screen-2xl">
        {render_slot(@inner_block)}
      </div>
    </main>
    """
  end
end
