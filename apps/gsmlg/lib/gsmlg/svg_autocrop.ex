defmodule GSMLG.SVG_Autocrop do
  @moduledoc """
  Auto-crop SVG files using svg-autocrop JS library via Denox (embedded V8 runtime).

  Loads `svg-autocrop` from esm.sh on first start and caches it locally under
  `priv/denox_cache/` so subsequent boots work offline.
  """

  use GenServer
  require Logger

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Auto-crop an SVG string.

  Accepts a map with a `"code"` key (the SVG) and an optional `"options"` key
  forwarded to the JS autocrop function.

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  @spec convert(map()) :: {:ok, term()} | {:error, term()}
  def convert(%{"code" => _} = data) do
    GenServer.call(__MODULE__, {:convert, data}, 30_000)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    {:ok, :not_initialized, {:continue, :init_runtime}}
  end

  @setup_code """
  globalThis.autocropSvg = async function(code, options) {
    const { default: autocrop } = await import("https://esm.sh/svg-autocrop");
    return await autocrop(code, options || {});
  };
  """

  @impl true
  def handle_continue(:init_runtime, _state) do
    try do
      cache_dir = Application.app_dir(:gsmlg, "priv/denox_cache")
      File.mkdir_p!(cache_dir)

      with {:ok, rt} <- Denox.runtime(cache_dir: cache_dir),
           :ok <- Denox.exec(rt, @setup_code) do
        Logger.info("#{__MODULE__} ready")
        {:noreply, rt}
      else
        {:error, reason} ->
          Logger.error("#{__MODULE__} failed to initialize: #{inspect(reason)}")
          {:noreply, :not_initialized}
      end
    rescue
      e ->
        Logger.error("#{__MODULE__} init raised: #{Exception.message(e)}")
        {:noreply, :not_initialized}
    end
  end

  @impl true
  def handle_call(_msg, _from, :not_initialized) do
    {:reply, {:error, :runtime_not_available}, :not_initialized}
  end

  def handle_call({:convert, data}, _from, rt) do
    svg_code = Map.get(data, "code", "")
    options = Map.get(data, "options", %{})

    result =
      with {:ok, json} <- Denox.call(rt, "autocropSvg", [svg_code, options]),
           {:ok, cropped} <- JSON.decode(json) do
        {:ok, cropped}
      end

    {:reply, result, rt}
  end
end
