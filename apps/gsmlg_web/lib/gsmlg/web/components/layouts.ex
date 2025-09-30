defmodule GSMLG.Web.Layouts do
  use GSMLG.Web, :html

  embed_templates "layouts/*"

  ## Phoenix 1.8 Unified Layout System

  @doc """
  Phoenix 1.8 unified layout component that replaces separate root.html.heex and app.html.heex.

  This component provides a single, explicit layout that can be composed and customized
  through slots and assigns, following Phoenix 1.8's explicitness-over-magic philosophy.
  """
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true
  slot :header, doc: "Header content"
  slot :footer, doc: "Footer content"
  slot :sidebar, doc: "Sidebar content"

  def unified_layout(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" data-theme="light">
      <head>
        <meta charset="utf-8" />
        <meta
          name="theme-color"
          media="(prefers-color-scheme: light)"
          content="oklch(95.86% 0.0693 95.91)"
        />
        <meta name="theme-color" media="(prefers-color-scheme: dark)" content="oklch(85.45% 0 0)" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <. Phoenix 1.8 title component %>
        <.live_title suffix="">
          {@page_title || gettext("GSMLG - Web Development & Tools")}
        </live_title>
        <link phx-track-static rel="stylesheet" href={~p"/assets/app.css"} />
        <script type="module">
          document.querySelector('meta[name=theme-color]').setAttribute('content', getComputedStyle(document.body).getPropertyValue('--color-primary'));
        </script>
        <script defer phx-track-static type="module" src={~p"/assets/app.js"}>
        </script>
        <%= if Application.get_env(:gsmlg_web, GSMLG.Web.Endpoint) |> Keyword.get(:enable_adsense) |> Kernel.==("yes") do %>
          <script
            async
            src="https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js?client=ca-pub-2900591828353755"
            crossorigin="anonymous"
          >
          </script>
        <% end %>
      </head>
      <body class={[
        "flex flex-col min-h-screen",
        "text-base-content bg-base-200",
        "overflow-x-hidden antialiased",
        @class
      ]} {@rest}>
        <!-- Phoenix 1.8 Theme Switcher -->
        <GSMLG.Web.Components.ThemeSwitcher.theme_switcher />

        <!-- Header Slot -->
        <%= if @header != [] do %>
          <%= render_slot(@header) %>
        <% else %>
          <!-- Default Header -->
          <. Phoenix 1.8 default header component %>
          <.unified_header />
        <% end %>

        <!-- Sidebar Slot -->
        <%= if @sidebar != [] do %>
          <div class="flex flex-1">
            <aside class="w-64 bg-base-100 shadow-lg">
              <%= render_slot(@sidebar) %>
            </aside>
            <main class="flex-1 container mx-auto px-4 py-8">
              <. Phoenix 1.8 flash component %>
              <.dm_flash_group flash={@flash} />
              <%= render_slot(@inner_block) %>
            </main>
          </div>
        <% else %>
          <!-- Main Content -->
          <main class={[
            "flex-1 container mx-auto px-4 py-8",
            "min-h-screen"
          ]}>
            <. Phoenix 1.8 flash component %>
            <.dm_flash_group flash={@flash} />
            <%= render_slot(@inner_block) %>
          </main>
        <% end %>

        <!-- Footer Slot -->
        <%= if @footer != [] do %>
          <%= render_slot(@footer) %>
        <% else %>
          <!-- Default Footer -->
          <.unified_footer />
        <% end %>
      </body>
    </html>
    """
  end

  @doc """
  Phoenix 1.8 unified header component.
  """
  attr :class, :string, default: nil
  attr :rest, :global

  def unified_header(assigns) do
    ~H"""
    <. Phoenix 1.8 header with daisyUI styling %>
    <header class={[
      "navbar bg-primary text-primary-content shadow-lg",
      @class
    ]} {@rest}>
      <div class="navbar-start">
        <a href={~p"/"} class="btn btn-ghost normal-case text-xl">GSMLG</a>
      </div>
      <div class="navbar-center hidden lg:flex">
        <ul class="menu menu-horizontal px-1">
          <li><a href={~p"/blogs"}>Blog</a></li>
          <li><a href={~p"/toolbox"}>Toolbox</a></li>
          <li><a href={~p"/about"}>About</a></li>
        </ul>
      </div>
      <div class="navbar-end">
        <div class="flex items-center gap-2">
          <a href="https://github.com/gsmlg-dev" target="_blank" class="btn btn-ghost btn-circle">
            <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 24 24">
              <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z"/>
            </svg>
          </a>
          <a href={~p"/auth/magic-link/new"} class="btn btn-ghost">Sign In</a>
        </div>
      </div>
    </header>
    """
  end

  @doc """
  Phoenix 1.8 unified footer component.
  """
  attr :class, :string, default: nil
  attr :rest, :global

  def unified_footer(assigns) do
    ~H"""
    <footer class={[
      "footer footer-center p-10 bg-base-300 text-base-content",
      @class
    ]} {@rest}>
      <div class="grid grid-flow-col gap-4">
        <a href={~p"/"} class="link link-hover">Home</a>
        <a href={~p"/blogs"} class="link link-hover">Blog</a>
        <a href={~p"/toolbox"} class="link link-hover">Toolbox</a>
        <a href={~p"/about"} class="link link-hover">About</a>
      </div>
      <div class="grid grid-flow-col gap-4">
        <a href="/toolbox/geoip2" class="link link-hover">GeoIP2 Database</a>
        <a href="/toolbox/whois" class="link link-hover">Domain/IP Whois</a>
        <a href="/toolbox/svg2react" class="link link-hover">SVG to React</a>
        <a href="/toolbox/mac_manufacturer" class="link link-hover">MAC Lookup</a>
      </div>
      <div>
        <p>Copyright © Jonathan Gao. All rights reserved</p>
      </div>
    </footer>
    """
  end
end
