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

    <main class="flex justify-center items-center flex-1 w-full">
      <div class="mx-auto w-full max-w-2xl">
        {render_slot(@inner_block)}
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
  Renders your user layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

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
        </.dm_left_menu>
      </div>
      <div class="flex flex-col flex-auto mx-auto max-w-screen-2xl">
        {render_slot(@inner_block)}
      </div>
    </main>
    """
  end
end
