defmodule GSMLG.Web.Hologram.Pages.MacManufacturer do
  use Hologram.Page

  alias GSMLG.Web.Hologram.Messages

  route("/toolbox/mac_manufacturer")
  layout(GSMLG.Web.Hologram.Shell)

  def init(_params, component, server) do
    component
    |> Messages.init(server)
    |> put_state(loading: false, result: nil, error: nil)
  end

  def action(:lookup, params, component) do
    component
    |> put_state(loading: true, result: nil, error: nil)
    |> put_command(:lookup, mac: String.trim(params.event["mac"]))
  end

  def action(:loaded, params, component) do
    put_state(component, loading: false, result: params.result, error: nil)
  end

  def action(:failed, params, component) do
    error = if is_atom(params.error), do: component.state.text[params.error], else: params.error
    put_state(component, loading: false, result: nil, error: error)
  end

  def command(:lookup, %{mac: mac}, server) when is_binary(mac) and byte_size(mac) <= 64 do
    if Regex.match?(~r/\A[0-9a-fA-F:.\-]+\z/, mac) and GSMLG.MAC.validate(mac) do
      case GSMLG.MAC.lookup_vendor(mac) do
        {:ok, short, full} -> put_action(server, :loaded, result: %{short: short, full: full})
        :error -> put_action(server, :failed, error: :unknown)
      end
    else
      put_action(server, :failed, error: :invalid_input)
    end
  end

  def command(:lookup, _params, server), do: put_action(server, :failed, error: :invalid_input)

  def template do
    ~HOLO"""
    <section class="container mx-auto px-6 my-12">
      <h1 class="text-4xl font-bold mb-8">{@text.mac_manufacturer}</h1>
      <form id="mac-form" $submit="lookup" class="flex flex-col gap-4 max-w-sm mx-auto">
        <label for="mac-input">MAC</label>
        <input id="mac-input" name="mac" class="input input-primary w-full" required maxlength="64" />
        <button id="mac-submit" class="btn btn-primary" type="submit" disabled={@loading}>
          {%if @loading}{@text.loading}{%else}{@text.lookup}{/if}
        </button>
      </form>
      <div id="mac-result" class="mt-6 max-w-xl mx-auto" aria-live="polite" aria-busy={@loading}>
        {%if @error}
          <div role="alert" class="alert alert-error">{@text.error}: {@error}</div>
        {/if}
        {%if @result}
          <dl class="card border border-base-300 p-6 grid grid-cols-1 sm:grid-cols-2 gap-3">
            <dt class="font-semibold">{@text.short}</dt><dd>{@result.short}</dd>
            <dt class="font-semibold">{@text.full_information}</dt><dd>{@result.full}</dd>
          </dl>
        {/if}
      </div>
    </section>
    """
  end
end
