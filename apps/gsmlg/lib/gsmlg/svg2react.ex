defmodule GSMLG.SVG2React do
  @moduledoc """
  Convert SVG to React components using @svgr/core via Denox (embedded V8 runtime).

  Loads `@svgr/core` from esm.sh on first start and caches it locally under
  `priv/denox_cache/` so subsequent boots work offline.
  """

  use GenServer
  require Logger

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Convert SVG code to a React component string.

  Accepts a map with a `"code"` key (the SVG) and an optional `"options"` key
  (forwarded directly to `@svgr/core` `transform/2`).

  Returns `{:ok, component_code}` or `{:error, reason}`.
  """
  @spec convert(map()) :: {:ok, String.t()} | {:error, term()}
  def convert(%{"code" => _} = data) do
    GenServer.call(__MODULE__, {:convert, data}, 30_000)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    {:ok, :not_initialized, {:continue, :init_runtime}}
  end

  @setup_code """
  globalThis.convertSvg = async function(code, options) {
    const { transform } = await import("https://esm.sh/@svgr/core@8");
    return await transform(code, options || {});
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
      with {:ok, json} <- Denox.call(rt, "convertSvg", [svg_code, options]),
           {:ok, component} <- JSON.decode(json) do
        {:ok, component}
      end

    {:reply, result, rt}
  end
end
