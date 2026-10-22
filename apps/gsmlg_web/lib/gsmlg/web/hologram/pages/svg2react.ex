defmodule GSMLG.Web.Hologram.Pages.Svg2React do
  use Hologram.Page

  alias GSMLG.Web.Hologram.Messages

  route("/toolbox/svg2react")
  layout(GSMLG.Web.Hologram.Shell)

  def init(_params, component, server) do
    component
    |> Messages.init(server)
    |> put_state(
      loading: false,
      result: nil,
      error: nil,
      unavailable: GSMLG.SVG2React.unavailable_message()
    )
  end

  def action(:lookup, params, component) do
    component
    |> put_state(loading: true, result: nil, error: nil)
    |> put_command(:lookup, code: params.event["code"])
  end

  def action(:loaded, params, component) do
    put_state(component, loading: false, result: params.result, error: nil)
  end

  def action(:failed, params, component) do
    error = if is_atom(params.error), do: component.state.text[params.error], else: params.error
    put_state(component, loading: false, result: nil, error: error)
  end

  def command(:lookup, %{code: code}, server)
      when is_binary(code) and byte_size(code) <= 1_000_000 do
    if String.trim(code) == "" do
      put_action(server, :failed, error: :invalid_input)
    else
      {:error, reason} = GSMLG.SVG2React.convert(conversion_data(code))
      put_action(server, :failed, error: reason)
    end
  rescue
    error in RuntimeError -> put_action(server, :failed, error: Exception.message(error))
  end

  def command(:lookup, _params, server), do: put_action(server, :failed, error: :invalid_input)

  @doc false
  def conversion_data(code) do
    %{
      "code" => code,
      "options" => %{
        "icon" => true,
        "native" => false,
        "typescript" => false,
        "ref" => true,
        "memo" => false,
        "titleProp" => false,
        "descProp" => false,
        "expandProps" => "end",
        "replaceAttrValues" => %{},
        "svgProps" => %{},
        "svgo" => true,
        "svgoConfig" => %{
          "plugins" => [
            %{"name" => "preset-default", "params" => %{"overrides" => %{"removeTitle" => false}}}
          ]
        },
        "prettier" => true,
        "prettierConfig" => %{"semi" => false}
      }
    }
  end

  def template do
    ~HOLO"""
    <section class="container mx-auto px-6 my-12">
      <h1 class="text-4xl font-bold mb-8">{@text.svg2react}</h1>
      <p role="status" class="alert alert-info mb-6">{@unavailable}</p>
      <form $submit="lookup" class="flex flex-col gap-6">
        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div class="flex flex-col gap-2">
            <label for="svg-input">SVG</label>
            <textarea id="svg-input" name="code" class="textarea textarea-primary w-full font-mono" rows="20" required maxlength="1000000"></textarea>
          </div>
          <div class="flex flex-col gap-2">
            <label for="svg-output">JSX</label>
            <textarea id="svg-output" class="textarea textarea-primary w-full font-mono" rows="20" readonly value={@result || ""}></textarea>
          </div>
        </div>
        <button id="svg-convert" type="submit" class="btn btn-primary w-full max-w-xs mx-auto" disabled>
          {%if @loading}{@text.loading}{%else}{@text.convert}{/if}
        </button>
      </form>
      <div class="my-4" aria-live="polite" aria-busy={@loading}>
        {%if @error}<div role="alert" class="alert alert-error">{@text.error}: {@error}</div>{/if}
      </div>
    </section>
    """
  end
end
