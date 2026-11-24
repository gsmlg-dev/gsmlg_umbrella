defmodule GSMLG.Web.Hologram.Pages.IpGeo do
  use Hologram.Page

  alias GSMLG.Web.Hologram.Messages

  route("/toolbox/ip_geo")
  layout(GSMLG.Web.Hologram.Shell, title_key: :ip_geo)

  def init(_params, component, server) do
    component
    |> Messages.init(server)
    |> put_state(loading: false, result: nil, error: nil)
  end

  def action(:lookup, params, component) do
    component
    |> put_state(loading: true, result: nil, error: nil)
    |> put_command(:lookup, ip: String.trim(params.event["ip"]))
  end

  def action(:loaded, params, component) do
    put_state(component, loading: false, result: params.result, error: nil)
  end

  def action(:failed, params, component) do
    error = if is_atom(params.error), do: component.state.text[params.error], else: params.error
    put_state(component, loading: false, result: nil, error: error)
  end

  def command(:lookup, _params, server),
    do: put_action(server, :failed, error: :service_unavailable)

  def template do
    ~HOLO"""
    <section class="container mx-auto px-6 my-12">
      <p role="status" class="alert alert-info mb-6">{@text.service_unavailable}</p>
      <form id="ip-geo-form" $submit="lookup" class="flex flex-col gap-4 max-w-sm mx-auto">
        <label for="ip-input">{@text.ip}</label>
        <input id="ip-input" name="ip" class="input input-primary w-full" disabled required maxlength="45" />
        <button id="ip-submit" type="submit" class="btn btn-primary" disabled>
          {%if @loading}{@text.loading}{%else}{@text.lookup}{/if}
        </button>
      </form>
      <div id="ip-result" class="my-6" aria-live="polite" aria-busy={@loading}>
        {%if @error}<div role="alert" class="alert alert-error">{@text.error}: {@error}</div>{/if}
        {%if @result}
          <dl class="card border border-base-300 p-6 grid grid-cols-1 sm:grid-cols-2 gap-3 max-w-xl mx-auto">
            <dt class="font-semibold">{@text.continent}</dt><dd>{Map.get(@result, :continent)}</dd>
            <dt class="font-semibold">{@text.country}</dt><dd>{Map.get(@result, :country)}</dd>
            <dt class="font-semibold">{@text.city}</dt><dd>{Map.get(@result, :city)}</dd>
            <dt class="font-semibold">{@text.coordinates}</dt><dd>{Map.get(@result, :latitude)}, {Map.get(@result, :longitude)}</dd>
          </dl>
        {/if}
      </div>
      <div id="ip-geo-map" role="img" aria-label={@text.service_unavailable} class="my-8 flex w-full aspect-2/1 items-center justify-center rounded-xl border border-outline-variant bg-surface-container-low text-on-surface-variant">
        <svg viewBox="0 0 120 80" class="h-32 w-48" fill="none" stroke="currentColor" aria-hidden="true">
          <ellipse cx="60" cy="40" rx="50" ry="30" />
          <ellipse cx="60" cy="40" rx="25" ry="30" />
          <path d="M10 40h100M60 10v60M17 25h86M17 55h86" />
        </svg>
      </div>
    </section>
    """
  end
end
