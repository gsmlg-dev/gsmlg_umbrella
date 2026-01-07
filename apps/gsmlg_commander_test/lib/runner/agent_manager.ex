defmodule GSMLG.CommanderTest.Runner.AgentManager do
  @moduledoc """
  Manages multiple test agent instances.

  Each agent is a real Commander agent that connects to the server
  over WebSocket, authenticates, and can spawn PTY sessions.

  This module provides functions to:
  - Start and stop test agents
  - Monitor agent status
  - Simulate network conditions
  - Retrieve PTY output

  """

  use GenServer

  alias GSMLG.CommanderTest.Helpers.ConfigGenerator
  alias GSMLG.CommanderTest.Client.TestAgent

  defstruct agents: %{}, config_files: %{}

  # Client API

  @doc """
  Start the AgentManager.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start a test agent with given configuration.

  ## Options

    * `:hostname` - Agent hostname
    * `:token` - Authentication token
    * `:capabilities` - List of capabilities
    * `:server_url` - WebSocket URL

  """
  @spec start_agent(map()) :: {:ok, String.t()} | {:error, term()}
  def start_agent(config) do
    # Generate a unique agent ID if not provided
    agent_id = Map.get(config, :agent_id, generate_agent_id())
    config = Map.put(config, :agent_id, agent_id)

    # Generate TOML config file
    case ConfigGenerator.generate_agent_config(config) do
      {:ok, config_path} ->
        # Start the agent under the DynamicSupervisor
        child_spec = {TestAgent, config_path: config_path, config: config}

        case DynamicSupervisor.start_child(GSMLG.CommanderTest.AgentSupervisor, child_spec) do
          {:ok, pid} ->
            # Track the agent
            GenServer.call(__MODULE__, {:register_agent, agent_id, pid, config_path})
            {:ok, agent_id}

          {:error, reason} ->
            ConfigGenerator.cleanup_config(config_path)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Start multiple agents with a configuration generator function.

  ## Examples

      {:ok, agent_ids} = AgentManager.start_agents(5, fn i ->
        %{hostname: "agent-\#{i}", token: token}
      end)

  """
  @spec start_agents(integer(), (integer() -> map())) :: {:ok, [String.t()]} | {:error, term()}
  def start_agents(count, config_fn) when is_function(config_fn, 1) do
    results =
      1..count
      |> Enum.map(fn i ->
        config = config_fn.(i)
        start_agent(config)
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      {:ok, Enum.map(results, fn {:ok, id} -> id end)}
    else
      {:error, {:some_agents_failed, errors}}
    end
  end

  @doc """
  Stop a specific agent.
  """
  @spec stop_agent(String.t()) :: :ok | {:error, :not_found}
  def stop_agent(agent_id) do
    GenServer.call(__MODULE__, {:stop_agent, agent_id})
  end

  @doc """
  Stop all agents.
  """
  @spec stop_all_agents() :: :ok
  def stop_all_agents do
    GenServer.call(__MODULE__, :stop_all)
  end

  @doc """
  Get the status of an agent.
  """
  @spec get_status(String.t()) :: atom() | nil
  def get_status(agent_id) do
    GenServer.call(__MODULE__, {:get_status, agent_id})
  end

  @doc """
  Wait for an agent to reach a specific status.
  """
  @spec wait_for_status(String.t(), atom(), integer()) :: :ok | {:error, :timeout}
  def wait_for_status(agent_id, status, timeout \\ 5000) do
    GSMLG.CommanderTest.Helpers.Wait.wait_for_status(agent_id, status, timeout: timeout)
  end

  @doc """
  Wait for all agents to be connected.
  """
  @spec wait_all_connected([String.t()], integer()) :: :ok | {:error, :timeout}
  def wait_all_connected(agent_ids, timeout \\ 10_000) do
    GSMLG.CommanderTest.Helpers.Wait.wait_all_connected(agent_ids, timeout: timeout)
  end

  @doc """
  Simulate network disconnect for an agent.
  """
  @spec disconnect_agent(String.t()) :: :ok | {:error, :not_found}
  def disconnect_agent(agent_id) do
    GenServer.call(__MODULE__, {:disconnect_agent, agent_id})
  end

  @doc """
  Trigger reconnection for an agent.
  """
  @spec reconnect_agent(String.t()) :: :ok | {:error, :not_found}
  def reconnect_agent(agent_id) do
    GenServer.call(__MODULE__, {:reconnect_agent, agent_id})
  end

  @doc """
  Get PTY output from an agent.
  """
  @spec get_pty_output(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def get_pty_output(agent_id, pty_id) do
    GenServer.call(__MODULE__, {:get_pty_output, agent_id, pty_id})
  end

  @doc """
  Send data to an agent's PTY.
  """
  @spec send_pty_input(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def send_pty_input(agent_id, pty_id, data) do
    GenServer.call(__MODULE__, {:send_pty_input, agent_id, pty_id, data})
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:register_agent, agent_id, pid, config_path}, _from, state) do
    new_state = %{
      state
      | agents: Map.put(state.agents, agent_id, pid),
        config_files: Map.put(state.config_files, agent_id, config_path)
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:stop_agent, agent_id}, _from, state) do
    case Map.get(state.agents, agent_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      pid ->
        # Stop the agent process
        DynamicSupervisor.terminate_child(GSMLG.CommanderTest.AgentSupervisor, pid)

        # Clean up config file
        case Map.get(state.config_files, agent_id) do
          nil -> :ok
          path -> ConfigGenerator.cleanup_config(path)
        end

        new_state = %{
          state
          | agents: Map.delete(state.agents, agent_id),
            config_files: Map.delete(state.config_files, agent_id)
        }

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:stop_all, _from, state) do
    # Stop all agents
    Enum.each(state.agents, fn {_id, pid} ->
      DynamicSupervisor.terminate_child(GSMLG.CommanderTest.AgentSupervisor, pid)
    end)

    # Clean up all config files
    Enum.each(state.config_files, fn {_id, path} ->
      ConfigGenerator.cleanup_config(path)
    end)

    {:reply, :ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:get_status, agent_id}, _from, state) do
    case Map.get(state.agents, agent_id) do
      nil ->
        {:reply, nil, state}

      pid ->
        status = TestAgent.get_status(pid)
        {:reply, status, state}
    end
  end

  @impl true
  def handle_call({:disconnect_agent, agent_id}, _from, state) do
    case Map.get(state.agents, agent_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      pid ->
        TestAgent.disconnect(pid)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:reconnect_agent, agent_id}, _from, state) do
    case Map.get(state.agents, agent_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      pid ->
        TestAgent.reconnect(pid)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:get_pty_output, agent_id, pty_id}, _from, state) do
    case Map.get(state.agents, agent_id) do
      nil ->
        {:reply, {:error, :agent_not_found}, state}

      pid ->
        result = TestAgent.get_pty_output(pid, pty_id)
        {:reply, result, state}
    end
  end

  @impl true
  def handle_call({:send_pty_input, agent_id, pty_id, data}, _from, state) do
    case Map.get(state.agents, agent_id) do
      nil ->
        {:reply, {:error, :agent_not_found}, state}

      pid ->
        result = TestAgent.send_pty_input(pid, pty_id, data)
        {:reply, result, state}
    end
  end

  # Private functions

  defp generate_agent_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
