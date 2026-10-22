defmodule GSMLG.Web.Layouts do
  use GSMLG.Web, :html
  import GSMLG.Web.Components.LanguageSwitcher

  # Phoenix 1.8: The file name becomes the function name
  # root.html.heex -> root/1 function
  # app.html.heex -> app/1 function
  # auth.html.heex -> auth/1 function
  # tool.html.heex -> tool/1 function

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

  slot :inner_block, required: true
  slot :header_slot, required: false

  def app(assigns) do
    ~H"""
    <.dm_page_header
      class={[
        "w-screen pop-menu",
        "bg-primary text-primary-content",
        "py-6 z-20"
      ]}
      nav_class={["shadow z-20 bg-primary text-primary-content"]}
    >
      <:menu to={~p"/"}>
        {dgettext("menu", "Home")}
      </:menu>
      <:menu to={~p"/blogs"}>
        {dgettext("menu", "Blog")}
      </:menu>
      <:menu to={~p"/toolbox"}>
        {dgettext("menu", "Toolbox")}
      </:menu>
      <:user_profile class="flex items-center gap-2">
        <.dm_theme_switcher />
        <.link class="flex flex-row gap-2" href="https://github.com/gsmlg-dev" target="_blank">
          <.dm_mdi name="github" class="h-10 w-10" />
        </.link>
      </:user_profile>
      {render_slot(@header_slot)}
    </.dm_page_header>
    <div class="pointer-events-none absolute top-84 overflow-x-clip w-full h-screen z-0">
      <.dm_art_snow id="snow-bg" unicode={true} />
    </div>
    <main class="flex flex-col items-center z-1">
      <.dm_flash_group flash={@flash} />
      {render_slot(@inner_block)}
    </main>
    """
  end

  attr :title, :string, required: true
  attr :catalogue, :boolean, required: true
  attr :locale, :string, required: true

  def toolbox(assigns) do
    ~H"""
    <.app flash={%{}}>
      <:header_slot>
        <section :if={@catalogue} class="w-full py-14 flex flex-col items-center gap-3 select-none">
          <div class="flex items-center gap-2 mb-1">
            <.dm_mdi name="toolbox-outline" class="w-5 h-5 text-primary-content/50" />
            <span class="font-mono text-[11px] tracking-[0.3em] uppercase text-primary-content/50">
              Developer Utilities
            </span>
          </div>
          <h1 class="header-hero-text text-primary-content font-black uppercase tracking-tighter drop-shadow-lg">
            {@title}
          </h1>
          <div class="flex items-center gap-4 mt-2" aria-hidden="true">
            <div class="w-16 h-px bg-primary-content/20"></div>
            <span class="font-mono text-[11px] text-primary-content/35 tracking-[0.25em] uppercase">
              7 tools available
            </span>
            <div class="w-16 h-px bg-primary-content/20"></div>
          </div>
        </section>
        <div :if={!@catalogue} class="header-hero-container">
          <h1 class="header-hero-text">{@title}</h1>
        </div>
      </:header_slot>
      <slot></slot>
    </.app>
    <.footer locale={@locale} />
    """
  end

  attr :locale, :string, required: true

  def footer(assigns) do
    ~H"""
    <.dm_page_footer class={[
      "bg-gradient-to-tl from-secondary to-accent",
      "text-neutral"
    ]}>
      <:section title={gettext("Language")}>
        <.language_switcher
          locale={@locale}
          supported_locales={GSMLG.Locale.supported()}
        />
      </:section>

      <:section title="Site Map">
        <.dm_link href={~p"/"}>{dgettext("menu", "Home")}</.dm_link>
        <.dm_link href={~p"/blogs"}>{dgettext("menu", "Blog")}</.dm_link>
        <.dm_link href={~p"/toolbox"}>{dgettext("menu", "Toolbox")}</.dm_link>
        <div class="w-24 h-[1px] bg-primary my-2"></div>
        <.dm_link href="/sign_in" class="uppercase">{dgettext("menu", "Sign In")}</.dm_link>
      </:section>

      <:section title="Toolbox">
        <.dm_link href="/toolbox/ip_geo">{dgettext("menu", "IP Geo Database")}</.dm_link>
        <.dm_link href="/toolbox/whois">{dgettext("menu", "Domain/IP/ASN Whois")}</.dm_link>
        <.dm_link href="/toolbox/svg2react">{dgettext("menu", "SVG to React")}</.dm_link>
        <.dm_link href="/toolbox/svg_autocrop">{dgettext("menu", "SVG AutoCrop")}</.dm_link>
        <.dm_link href="/toolbox/mac_manufacturer">
          {dgettext("menu", "Lookup MAC Manufacturer")}
        </.dm_link>
      </:section>

      <:copyright title="Copyright">
        <span>{gettext("Copyright© Jonathan Gao. All rights reserved")}</span>
      </:copyright>
    </.dm_page_footer>
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
    <main class="flex justify-center items-center min-h-screen">
      <div class="flex flex-col justify-center items-center max-w-2xl">
        <.dm_flash_group flash={@flash} />
        {render_slot(@inner_block)}
      </div>
    </main>
    """
  end
end
