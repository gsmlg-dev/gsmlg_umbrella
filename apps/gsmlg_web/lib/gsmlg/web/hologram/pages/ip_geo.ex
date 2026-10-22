defmodule GSMLG.Web.Hologram.Pages.IpGeo do
  use Hologram.Page

  alias GSMLG.Web.Hologram.{Browser, Messages}

  route("/toolbox/ip_geo")
  layout(GSMLG.Web.Hologram.Shell, title_key: :ip_geo)

  def init(_params, component, server) do
    component
    |> Messages.init(server)
    |> put_state(loading: false, result: nil, error: nil)
    |> put_action(:mount_map)
  end

  def action(:mount_map, _params, component) do
    if Browser.mount_map("ip-geo-map") do
      component
    else
      put_state(component, :error, component.state.text.browser_unavailable)
    end
  end

  def action(:lookup, params, component) do
    component
    |> put_state(loading: true, result: nil, error: nil)
    |> put_command(:lookup, ip: String.trim(params.event["ip"]))
  end

  def action(:loaded, params, component) do
    case params.result do
      %{latitude: latitude, longitude: longitude}
      when is_number(latitude) and is_number(longitude) ->
        Browser.update_map("ip-geo-map", [[longitude, latitude]], longitude)

      _ ->
        Browser.update_map("ip-geo-map", [], 0)
    end

    put_state(component, loading: false, result: params.result, error: nil)
  end

  def action(:failed, params, component) do
    error = if is_atom(params.error), do: component.state.text[params.error], else: params.error
    put_state(component, loading: false, result: nil, error: error)
  end

  def command(:lookup, %{ip: ip}, server) when is_binary(ip) and byte_size(ip) <= 45 do
    with {:ok, _address} <- :inet.parse_address(String.to_charlist(ip)),
         {:ok, result} <- GSMLG.IpGeo.lookup(ip) do
      put_action(server, :loaded, result: result)
    else
      {:error, :einval} -> put_action(server, :failed, error: :invalid_input)
      {:error, reason} -> put_action(server, :failed, error: inspect(reason))
    end
  end

  def command(:lookup, _params, server), do: put_action(server, :failed, error: :invalid_input)

  def template do
    ~HOLO"""
    <section class="container mx-auto px-6 my-12">
      <form id="ip-geo-form" $submit="lookup" class="flex flex-col gap-4 max-w-sm mx-auto">
        <label for="ip-input">{@text.ip}</label>
        <input id="ip-input" name="ip" class="input input-primary w-full" required maxlength="45" />
        <button id="ip-submit" type="submit" class="btn btn-primary" disabled={@loading}>
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
      <d3-world-map id="ip-geo-map" class="block w-full aspect-2/1" points="[]" center-longitude="0"></d3-world-map>
    </section>
    """
  end
end
