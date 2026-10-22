defmodule GSMLG.Web.Hologram.Pages.SvgAutocrop do
  use Hologram.Page

  alias GSMLG.Web.Hologram.{Browser, Messages, Shell}

  route("/toolbox/svg_autocrop")
  layout(Shell, title_key: :svg_autocrop)

  @impl true
  def init(_params, component, server) do
    component
    |> Messages.init(server)
    |> put_state(source: "", output: "", loading: false, error: nil)
  end

  @impl true
  def action(:edit_source, %{event: %{value: source}}, component) do
    put_state(component, :source, source)
  end

  def action(:convert, %{event: %{"code" => source}}, component) do
    if String.trim(source) == "" do
      put_state(component, error: component.state.text.invalid_input, loading: false)
    else
      component
      |> put_state(source: source, output: "", loading: true, error: nil)
      |> put_action(:crop)
    end
  end

  def action(:crop, _params, component) do
    case Browser.autocrop_svg(component.state.source) do
      %{"ok" => true, "output" => output} ->
        put_state(component, output: output, loading: false, error: nil)

      %{"error" => error} ->
        put_state(component, output: "", loading: false, error: error)
    end
  end

  @impl true
  def template do
    ~HOLO"""
    <div class="container mx-auto px-6 my-12">
      <form class="flex flex-col gap-6" $submit="convert">
        <div class="grid gap-6 md:grid-cols-2">
          <label class="flex flex-col gap-2">{@text.origin_svg}
            <textarea id="svg-input" name="code" class="textarea textarea-primary w-full" rows="20" value={@source} $input="edit_source"></textarea>
          </label>
          <label class="flex flex-col gap-2">{@text.optimized_svg}
            <textarea id="svg-output" class="textarea textarea-primary w-full" rows="20" readonly value={@output}></textarea>
          </label>
        </div>
        <button id="svg-convert" type="submit" class="btn btn-primary self-center" disabled={@loading}>{@text.optimize}</button>
        {%if @loading}<p role="status">{@text.loading}</p>{/if}
        {%if @error}<p role="alert" class="alert alert-error">{@error}</p>{/if}
      </form>
    </div>
    """
  end
end
