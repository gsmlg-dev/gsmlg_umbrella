defmodule GSMLG.Web.Hologram.Shell do
  @moduledoc false
  use Hologram.Component

  alias GSMLG.Web.Hologram.{Browser, LayoutDOM, Messages}
  alias Hologram.UI.Runtime

  prop(:title_key, :atom, default: :toolbox)

  @impl true
  def init(props, component, server) do
    component = Messages.init(component, server)
    title = Map.fetch!(component.state.text, props.title_key)

    layout_dom =
      Gettext.with_locale(GSMLG.Web.Gettext, component.state.locale, fn ->
        GSMLG.Web.Layouts.toolbox(%{
          __changed__: nil,
          title: title,
          catalogue: props.title_key == :toolbox,
          locale: component.state.locale
        })
        |> LayoutDOM.from_rendered()
      end)

    component
    |> put_state(:stylesheet, GSMLG.Web.Endpoint.static_path("/assets/app.css"))
    |> put_state(:theme, "sunshine")
    |> put_state(:title, title)
    |> put_state(:layout_dom, layout_dom)
    |> put_action(:restore_theme)
  end

  @impl true
  def action(:restore_theme, _params, component) do
    put_state(component, :theme, Browser.mount_layout())
  end

  @impl true
  def template do
    fn vars ->
      head =
        ~HOLO"""
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <title>{@title} · GSMLG</title>
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
        """

      [
        {:doctype, "html"},
        {:element, "html", [{"lang", [text: vars.locale]}, {"data-theme", [text: vars.theme]}],
         head.(vars) ++
           [
             {:element, "body",
              [
                {"class",
                 [
                   text:
                     "flex min-h-screen flex-col bg-surface text-on-surface overflow-x-hidden antialiased"
                 ]}
              ], vars.layout_dom}
           ]}
      ]
    end
  end
end
