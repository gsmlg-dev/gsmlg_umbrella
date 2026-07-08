defmodule GSMLG.CommandPlatform do
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
    GSMLG.Telemetry.info("Commander joined platform",
      metadata: %{
        module: __MODULE__,
        event: "commander_joined",
        commander_name: Map.get(commander, :name),
        commander_peer_data: Map.get(commander, :peer_data),
        node: node()
      }
    )

    CommandPlatform.Agent.add_commander(commander)
  end

  def commander_leave(commander) do
    GSMLG.Telemetry.info("Commander left platform",
      metadata: %{
        module: __MODULE__,
        event: "commander_left",
        commander_name: Map.get(commander, :name),
        node: node()
      }
    )

    CommandPlatform.Agent.remove_commander(commander)
  end

  def add_run_result(result) do
    GSMLG.Telemetry.debug("Adding command run result",
      metadata: %{
        module: __MODULE__,
        operation: "add_run_result",
        command: Map.get(result, :command),
        commander: Map.get(result, :commander),
        exit_code: Map.get(result, :code)
      }
    )

    GenServer.cast(__MODULE__, {:add_run_result, result})
  end

  @impl true
  def init(_init) do
    state = %{commanders: [], run_results: []}

    GSMLG.Telemetry.info("CommandPlatform initializing",
      metadata: %{
        module: __MODULE__,
        operation: "init",
        node: node(),
        initial_state_keys: Map.keys(state)
      }
    )

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    GSMLG.Telemetry.debug("CommandPlatform state requested",
      metadata: %{
        module: __MODULE__,
        operation: "get_state",
        commanders_count: length(state.commanders),
        results_count: length(state.run_results)
      }
    )

    {:reply, {:ok, state}, state}
  end

  def handle_call(:list_commanders, _from, %{:commanders => commanders} = state) do
    GSMLG.Telemetry.debug("Commanders list requested",
      metadata: %{
        module: __MODULE__,
        operation: "list_commanders",
        commanders_count: length(commanders)
      }
    )

    {:reply, {:ok, commanders}, state}
  end

  def handle_call(:list_command_results, _from, %{:run_results => run_results} = state) do
    GSMLG.Telemetry.debug("Command results list requested",
      metadata: %{
        module: __MODULE__,
        operation: "list_command_results",
        results_count: length(run_results)
      }
    )

    {:reply, {:ok, run_results}, state}
  end

  @impl true
  def handle_cast({:commander_joined, commander}, state) do
    new_commanders_count = length(state.commanders) + 1

    new_state =
      state
      |> update_in([:commanders], fn commanders ->
        [commander | commanders]
      end)

    GSMLG.Telemetry.info("Commander added to state",
      metadata: %{
        module: __MODULE__,
        operation: "commander_added",
        commander_name: Map.get(commander, :name),
        previous_commanders_count: length(state.commanders),
        new_commanders_count: new_commanders_count
      }
    )

    {:noreply, new_state}
  end

  def handle_cast({:commander_leave, commander}, state) do
    new_state =
      state
      |> update_in([:commanders], fn commanders ->
        commanders |> Enum.reject(&(&1.name == commander.name))
      end)

    new_commanders_count = length(new_state.commanders)
    commanders_removed = length(state.commanders) - new_commanders_count

    GSMLG.Telemetry.info("Commander removed from state",
      metadata: %{
        module: __MODULE__,
        operation: "commander_removed",
        commander_name: Map.get(commander, :name),
        previous_commanders_count: length(state.commanders),
        new_commanders_count: new_commanders_count,
        commanders_removed: commanders_removed
      }
    )

    {:noreply, new_state}
  end

  def handle_cast({:add_run_result, result}, state) do
    new_results_count = length(state.run_results) + 1

    new_state =
      state
      |> update_in([:run_results], fn run_results ->
        [result | run_results]
      end)

    GSMLG.Telemetry.info("Command result added to state",
      metadata: %{
        module: __MODULE__,
        operation: "result_added",
        command: Map.get(result, :command),
        commander: Map.get(result, :commander),
        exit_code: Map.get(result, :code),
        previous_results_count: length(state.run_results),
        new_results_count: new_results_count
      }
    )

    {:noreply, new_state}
  end

  @impl true
  def handle_info(msg, state) do
    GSMLG.Telemetry.warn("Unexpected message received in CommandPlatform",
      metadata: %{
        module: __MODULE__,
        operation: "unexpected_message",
        message: msg,
        message_type: typeof(msg),
        state_keys: Map.keys(state)
      }
    )

    {:noreply, state}
  end

  defp typeof(term) when is_map(term), do: :map
  defp typeof(term) when is_list(term), do: :list
  defp typeof(term) when is_binary(term), do: :binary
  defp typeof(term) when is_number(term), do: :number
  defp typeof(term) when is_atom(term), do: :atom
  defp typeof(_), do: :unknown
end
