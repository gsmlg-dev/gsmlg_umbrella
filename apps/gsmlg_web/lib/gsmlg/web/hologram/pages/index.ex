defmodule GSMLG.Web.Hologram.Pages.Index do
  use Hologram.Page

  alias GSMLG.Web.Hologram.Messages

  route("/toolbox")
  layout(GSMLG.Web.Hologram.Shell, title_key: :toolbox)

  def init(_params, component, server) do
    component = Messages.init(component, server)
    text = component.state.text

    put_state(component, :tools, [
      %{title: text.ip_geo, description: text.ip_geo_description, path: "/toolbox/ip_geo"},
      %{title: text.whois, description: text.whois_description, path: "/toolbox/whois"},
      %{
        title: text.mac_manufacturer,
        description: text.mac_description,
        path: "/toolbox/mac_manufacturer"
      },
      %{
        title: text.svg2react,
        description: text.svg2react_description,
        path: "/toolbox/svg2react"
      },
      %{
        title: text.svg_autocrop,
        description: text.svg_autocrop_description,
        path: "/toolbox/svg_autocrop"
      },
      %{
        title: text.ip_to_geomap,
        description: text.ip_to_geomap_description,
        path: "/toolbox/ip_to_geomap"
      },
      %{
        title: text.screensaver,
        description: text.screensaver_description,
        path: "/toolbox/screensaver"
      }
    ])
  end

  def template do
    ~HOLO"""
    <section class="w-full max-w-screen-xl px-6 mx-auto my-12">
      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-5">
        {%for tool <- @tools}
          <article class="card border border-base-300 shadow-sm transition-transform hover:-translate-y-1">
            <div class="card-body gap-4">
              <h2 class="card-title text-lg">{tool.title}</h2>
              <p class="text-sm text-base-content/60 leading-relaxed min-h-10">{tool.description}</p>
              <a href={tool.path} class="btn btn-primary w-full">{@text.open} →</a>
            </div>
          </article>
        {/for}
      </div>
    </section>
    """
  end
end
