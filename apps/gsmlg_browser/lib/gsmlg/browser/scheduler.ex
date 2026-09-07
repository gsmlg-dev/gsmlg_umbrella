defmodule GSMLG.Browser.Scheduler do
  @moduledoc false

  use GenServer

  alias GSMLG.Browser.Enabled
  alias GSMLG.Browser.Workers.{ReconcileSweepWorker, RetentionWorker}

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms:
        Keyword.get(
          opts,
          :interval_ms,
          Application.get_env(:gsmlg_browser, :reconcile_interval_ms, 30_000)
        ),
      insert: Keyword.get(opts, :insert, &Oban.insert/1)
    }

    if Enabled.ensure() == :ok, do: send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    _ = state.insert.(ReconcileSweepWorker.new(%{}))
    _ = state.insert.(RetentionWorker.new(%{}))
    Process.send_after(self(), :tick, max(state.interval_ms, 1_000))
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
