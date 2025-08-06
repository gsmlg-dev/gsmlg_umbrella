defmodule GSMLG.CommandPlatform do
  require Logger
  use GenServer
  alias GSMLG.CommandPlatform

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc """
  Get CommandPlatform state
  """
  @spec get_state() :: {:ok, term} | {:error, term}
  def get_state() do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :not_running}

      _pid ->
        GenServer.call(__MODULE__, :get_state)
    end
  end

  def list_commanders() do
    CommandPlatform.Agent.commanders()
  end

  def list_command_results() do
    GenServer.call(__MODULE__, :list_command_results)
  end

  def commander_joined(commander) do
    Logger.info("Commander joined: #{inspect(commander)}")

    CommandPlatform.Agent.add_commander(commander)
  end

  def commander_leave(commander) do
    Logger.info("Commander leave: #{inspect(commander)}")

    CommandPlatform.Agent.remove_commander(commander)
  end

  def add_run_result(result) do
    GenServer.cast(__MODULE__, {:add_run_result, result})
  end

  @impl true
  def init(_init) do
    state = %{commanders: [], run_results: []}
    Logger.debug("CommandPlatform init state: #{inspect(state)}")
    {:ok, state}
  end

  @impl true
  def handle_continue(:start_mnesia, state) do
    ensure_mnesia_started()
    ensure_mnesia_table()

    Logger.debug("CommandPlatform initialize state: #{inspect(state)}")

    {:noreply, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    Logger.debug("CommandPlatform state: #{inspect(state)}")
    {:reply, {:ok, state}, state}
  end

  def handle_call(:list_commanders, _from, %{:commanders => commanders} = state) do
    Logger.debug("CommandPlatform state: #{inspect(state)}")
    {:reply, {:ok, commanders}, state}
  end

  def handle_call(:list_command_results, _from, %{:run_results => run_results} = state) do
    {:reply, {:ok, run_results}, state}
  end

  @impl true
  def handle_cast({:commander_joined, commander}, state) do
    state =
      state
      |> update_in([:commanders], fn commanders ->
        [commander | commanders]
      end)

    Logger.debug("Commanders updated: #{inspect(state)}")
    {:noreply, state}
  end

  def handle_cast({:commander_leave, commander}, state) do
    state =
      state
      |> update_in([:commanders], fn commanders ->
        commanders |> Enum.reject(&(&1.name == commander.name))
      end)

    Logger.debug("Commanders updated: #{inspect(state)}")
    {:noreply, state}
  end

  def handle_cast({:add_run_result, result}, state) do
    state =
      state
      |> update_in([:run_results], fn run_results ->
        [result | run_results]
      end)

    Logger.debug("Add new run result: #{inspect(result)}")
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("Unexpected message in KV.Registry: #{inspect(msg)}")
    {:noreply, state}
  end

  defp ensure_mnesia_started() do
    GSMLG.Mnesia.stop()
    GSMLG.Mnesia.Schema.create([node()])

    case GSMLG.Mnesia.start() do
      :ok -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, _} = error -> error
    end
  end

  defp ensure_mnesia_table() do
    CommandPlatform.Commander.ensure_table()
  end
end
