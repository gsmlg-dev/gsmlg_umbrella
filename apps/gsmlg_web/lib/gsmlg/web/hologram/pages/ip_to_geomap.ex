defmodule GSMLG.Web.Hologram.Pages.IpToGeomap do
  use Hologram.Page

  alias GSMLG.Web.Hologram.{Browser, Messages, Shell}

  route("/toolbox/ip_to_geomap")
  layout(Shell, title_key: :ip_to_geomap)

  @impl true
  def init(_params, component, server) do
    component
    |> Messages.init(server)
    |> put_state(ips: "", points: [], remaining: [], loading: false, error: nil)
    |> put_action(:setup)
  end

  @impl true
  def action(:setup, _params, component) do
    if Browser.mount_map("ip-geo-map") do
      component
    else
      put_state(component, :error, component.state.text.browser_unavailable)
    end
  end

  def action(:edit_ips, %{event: %{value: ips}}, component) do
    put_state(component, :ips, ips)
  end

  def action(:lookup, %{event: %{"ips" => ips}}, component) do
    case String.split(ips) do
      [] ->
        put_state(component, error: component.state.text.invalid_input, loading: false)

      [ip | remaining] ->
        Browser.update_map("ip-geo-map", [], nil)

        component
        |> put_state(ips: ips, remaining: remaining, points: [], loading: true, error: nil)
        |> put_command(:lookup, ip: ip)
    end
  end

  def action(:located, %{point: point}, component) do
    points = if point, do: component.state.points ++ [point], else: component.state.points
    Browser.update_map("ip-geo-map", points, nil)
    component = put_state(component, :points, points)

    case component.state.remaining do
      [] ->
        put_state(component, :loading, false)

      [ip | remaining] ->
        component |> put_state(:remaining, remaining) |> put_command(:lookup, ip: ip)
    end
  end

  @impl true
  def command(:lookup, %{ip: ip}, server) when is_binary(ip) do
    point =
      case GSMLG.IpGeo.lookup(ip) do
        {:ok, %{latitude: lat, longitude: lon}} when is_number(lat) and is_number(lon) ->
          [lon, lat]

        _ ->
          nil
      end

    put_action(server, :located, point: point)
  end

  def command(:lookup, _params, server), do: put_action(server, :located, point: nil)

  @impl true
  def template do
    ~HOLO"""
    <div class="container mx-auto px-6 my-12">
      <form class="flex flex-col gap-4" $submit="lookup">
        <label for="ip-data">{@text.ip}</label>
        <textarea id="ip-data" name="ips" rows="6" class="textarea textarea-primary w-full" value={@ips} $input="edit_ips"></textarea>
        <button id="submit-ip" type="submit" class="btn btn-primary self-start" disabled={@loading}>{@text.lookup}</button>
      </form>
      {%if @loading}<p role="status" class="my-4">{@text.loading}</p>{/if}
      {%if @error}<p role="alert" class="alert alert-error my-4">{@error}</p>{/if}
      <d3-world-map id="ip-geo-map" class="block w-full aspect-2/1 my-8" points="[]"></d3-world-map>
    </div>
    """
  end
end
