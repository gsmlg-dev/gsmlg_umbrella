defmodule GSMLG.Web.Hologram.Shell do
  @moduledoc false
  use Hologram.Component

  alias GSMLG.Web.Hologram.{Browser, Messages}
  alias GSMLG.Web.Hologram.Pages.Index
  alias Hologram.UI.{Link, Runtime}

  @locale_names %{
    "zh-Hans" => "简体中文",
    "zh-Hant" => "繁體中文",
    "en" => "English",
    "fr" => "Français",
    "es" => "Español",
    "de" => "Deutsch",
    "it" => "Italiano",
    "ja" => "日本語"
  }

  @impl true
  def init(_props, component, server) do
    component
    |> Messages.init(server)
    |> put_state(:stylesheet, GSMLG.Web.Endpoint.static_path("/assets/app.css"))
    |> put_state(:theme, "sunshine")
    |> put_state(
      :languages,
      Enum.map(GSMLG.Locale.supported(), &%{code: &1, name: @locale_names[&1]})
    )
    |> put_action(:restore_theme)
  end

  @impl true
  def action(:restore_theme, _params, component) do
    put_state(component, :theme, Browser.stored_theme())
  end

  def action(:toggle_theme, _params, component) do
    put_state(component, :theme, Browser.toggle_theme())
  end

  @impl true
  def template do
    ~HOLO"""
    <!DOCTYPE html>
    <html lang={@locale} data-theme={@theme}>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{@text.toolbox} · GSMLG</title>
        <link rel="stylesheet" href={@stylesheet} />
        <script>
          {%raw}
          (() => {
            const stored = localStorage.getItem("theme");
            const theme = stored && stored !== "default" ? stored :
              (matchMedia("(prefers-color-scheme: dark)").matches ? "moonlight" : "sunshine");
            document.documentElement.setAttribute("data-theme", theme);
          })();
          {/raw}
        </script>
        <Runtime />
      </head>
      <body class="flex min-h-screen flex-col bg-surface text-on-surface overflow-x-hidden antialiased">
        <header class="bg-primary text-primary-content py-6">
          <nav class="mx-auto flex max-w-screen-xl flex-wrap items-center gap-6 px-6" aria-label="Main">
            <a href="/">{@text.home}</a>
            <a href="/blogs">{@text.blog}</a>
            <Link to={Index} class="font-semibold">{@text.toolbox}</Link>
            <button type="button" class="btn btn-ghost btn-sm ml-auto" $click="toggle_theme">{@text.theme}</button>
            <a href="https://github.com/gsmlg-dev" target="_blank" rel="noopener noreferrer">GitHub</a>
          </nav>
        </header>
        <main class="container mx-auto flex-1 px-6 py-12"><slot /></main>
        <footer class="mt-12 bg-gradient-to-tl from-secondary to-accent px-6 py-10 text-neutral">
          <div class="mx-auto flex max-w-screen-xl flex-wrap justify-between gap-8">
            <section>
              <h2 class="mb-3 font-semibold">{@text.language}</h2>
              <div class="flex flex-wrap gap-3">
                {%for language <- @languages}
                  <a href={"?lang=" <> language.code} lang={language.code} aria-current={language.code == @locale}>{language.name}</a>
                {/for}
              </div>
            </section>
            <nav class="flex gap-4" aria-label="Footer">
              <a href="/">{@text.home}</a><a href="/blogs">{@text.blog}</a>
              <Link to={Index}>{@text.toolbox}</Link>
            </nav>
            <p>Copyright© Jonathan Gao. All rights reserved</p>
          </div>
        </footer>
      </body>
    </html>
    """
  end
end
