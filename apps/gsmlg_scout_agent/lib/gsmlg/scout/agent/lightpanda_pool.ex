defmodule GSMLG.Scout.Agent.LightpandaPool do
  @moduledoc """
  Pool that bounds Lightpanda fetch execution.
  """

  @behaviour NimblePool

  @table __MODULE__

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  def start_link(opts) do
    settings = GSMLG.Scout.Settings.get()

    NimblePool.start_link(
      worker: {__MODULE__, opts},
      name: __MODULE__,
      pool_size: Keyword.get(opts, :pool_size, settings["agent"]["browser_instances"])
    )
  end

  def fetch(url, opts) do
    timeout = (opts["timeout_ms"] || opts[:timeout_ms] || 30_000) + 1_000

    NimblePool.checkout!(
      __MODULE__,
      {:fetch, url, opts},
      fn _from, {adapter, fetch_url, fetch_opts} ->
        {adapter.fetch(fetch_url, fetch_opts), {adapter, fetch_url, fetch_opts}}
      end,
      timeout
    )
  end

  def running_count do
    case :ets.whereis(@table) do
      :undefined ->
        0

      _table ->
        case :ets.lookup(@table, :running_jobs) do
          [{:running_jobs, count}] -> count
          [] -> 0
        end
    end
  end

  @impl true
  def init_pool(opts) do
    ensure_table()

    adapter =
      Keyword.get(
        opts,
        :adapter,
        Application.get_env(
          :gsmlg_scout_agent,
          :lightpanda_adapter,
          GSMLG.Scout.Agent.Lightpanda.CLI
        )
      )

    {:ok, %{adapter: adapter}}
  end

  @impl true
  def init_worker(pool_state) do
    {:ok, %{}, pool_state}
  end

  @impl true
  def handle_checkout({:fetch, url, opts}, _from, worker_state, pool_state) do
    increment_running()
    {:ok, {pool_state.adapter, url, opts}, worker_state, pool_state}
  end

  @impl true
  def handle_checkin(_client_state, _from, worker_state, pool_state) do
    decrement_running()
    {:ok, worker_state, pool_state}
  end

  @impl true
  def terminate_worker(_reason, _worker_state, pool_state), do: {:ok, pool_state}

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, read_concurrency: true])
        :ets.insert(@table, {:running_jobs, 0})

      _table ->
        :ets.insert(@table, {:running_jobs, 0})
    end
  end

  defp increment_running do
    :ets.update_counter(@table, :running_jobs, {2, 1}, {:running_jobs, 0})
  end

  defp decrement_running do
    :ets.update_counter(@table, :running_jobs, {2, -1, 0, 0}, {:running_jobs, 0})
  end
end
