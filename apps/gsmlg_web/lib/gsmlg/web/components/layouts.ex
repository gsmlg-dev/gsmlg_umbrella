defmodule GSMLG.Web.Layouts do
  use GSMLG.Web, :html

  alias GSMLG.Web.Layouts

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
      <section class={[
        "w-full h-64",
        "font-bold select-none drop-shadow-md text-shadow-lg",
        "flex flex-col items-center justify-evenly"
      ]}>
        <h2 class="header-hero-text uppercase">
          {dgettext("homepage", "slogan-1")}
        </h2>
        <h2 class="header-hero-text uppercase">
          {dgettext("homepage", "slogan-2")}
        </h2>
      </section>
    </.dm_page_header>
    <div class="absolute top-84 overflow-x-clip w-full h-screen z-0">
      <.dmf_snow count={365} size="1.25rem" unicode />
    </div>
    <main class="flex flex-col items-center z-1">
      <.dm_flash_group flash={@flash} />
      {@inner_content}
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
    <main class="flex justify-center items-center min-h-screen">
      <div class="flex flex-col justify-center items-center max-w-2xl">
        <.dm_flash_group flash={@flash} />
        {@inner_content}
      </div>
    </main>
    """
  end


  @doc """
  Renders your tool layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.tool flash={@flash}>
        <h1>Content</h1>
      </Layouts.tool>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true
  def tool(assigns) do
    ~H"""
    <.dm_page_header
      class={[
        "bg-primary text-primary-content",
        "h-fit py-6"
      ]}
      nav_class={["bg-primary text-primary-content shadow z-20"]}
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
      <%= if assigns[:header_slot] do %>
        {@header_slot}
      <% end %>
    </.dm_page_header>
    <main class="flex flex-col items-center min-h-[calc(100vh-320px-316px)]">
      <.dm_flash_group flash={@flash} />
      {@inner_content}
    </main>
    """
  end
end
