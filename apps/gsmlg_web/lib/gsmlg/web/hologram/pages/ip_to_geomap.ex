defmodule GSMLG.Web.Hologram.Pages.IpToGeomap do
  use Hologram.Page

  alias GSMLG.Web.Hologram.{Messages, Shell}

  route("/toolbox/ip_to_geomap")
  layout(Shell, title_key: :ip_to_geomap)

  @impl true
  def init(_params, component, server) do
    component
    |> Messages.init(server)
    |> put_state(ips: "", points: [], remaining: [], loading: false, error: nil)
  end

  @impl true
  def action(:edit_ips, %{event: %{value: ips}}, component) do
    put_state(component, :ips, ips)
  end

  def action(:lookup, %{event: %{"ips" => ips}}, component) do
    case String.split(ips) do
      [] ->
        put_state(component, error: component.state.text.invalid_input, loading: false)

      [ip | remaining] ->
        component
        |> put_state(ips: ips, remaining: remaining, points: [], loading: true, error: nil)
        |> put_command(:lookup, ip: ip)
    end
  end

  def action(:located, %{point: point}, component) do
    points = if point, do: component.state.points ++ [point], else: component.state.points
    component = put_state(component, :points, points)

    case component.state.remaining do
      [] ->
        put_state(component, :loading, false)

      [ip | remaining] ->
        component |> put_state(:remaining, remaining) |> put_command(:lookup, ip: ip)
    end
  end

  def action(:failed, %{error: error}, component) do
    put_state(component,
      loading: false,
      remaining: [],
      points: [],
      error: component.state.text[error]
    )
  end

  @impl true
  def command(:lookup, _params, server),
    do: put_action(server, :failed, error: :service_unavailable)

  @impl true
  def template do
    ~HOLO"""
    <div class="container mx-auto px-6 my-12">
      <p role="status" class="alert alert-info mb-6">{@text.service_unavailable}</p>
      <form class="flex flex-col gap-4" $submit="lookup">
        <label for="ip-data">{@text.ip}</label>
        <textarea disabled id="ip-data" name="ips" rows="6" class="textarea textarea-primary w-full" value={@ips} $input="edit_ips"></textarea>
        <button id="submit-ip" type="submit" class="btn btn-primary self-start" disabled>{@text.lookup}</button>
      </form>
      {%if @loading}<p role="status" class="my-4">{@text.loading}</p>{/if}
      {%if @error}<p role="alert" class="alert alert-error my-4">{@error}</p>{/if}
      <div id="ip-geo-map" role="img" aria-label={@text.service_unavailable} class="my-8 flex w-full aspect-2/1 items-center justify-center rounded-xl border border-outline-variant bg-surface-container-low text-on-surface-variant">
        <svg viewBox="0 0 120 80" class="h-32 w-48" fill="none" stroke="currentColor" aria-hidden="true">
          <ellipse cx="60" cy="40" rx="50" ry="30" />
          <ellipse cx="60" cy="40" rx="25" ry="30" />
          <path d="M10 40h100M60 10v60M17 25h86M17 55h86" />
        </svg>
      </div>
    </div>
    """
  end
end
