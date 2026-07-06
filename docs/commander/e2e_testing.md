# Commander E2E Testing System - Design Document

**Project:** gsmlg_commander_test (standalone application in gsmlg_umbrella)  
**Version:** 2.0  
**Date:** January 2026  
**Author:** Jonathan (GSMLG)

---

## Table of Contents

1. [Overview](#overview)
2. [Testing Philosophy](#testing-philosophy)
3. [Architecture](#architecture)
4. [Module Structure](#module-structure)
5. [Test Components](#test-components)
6. [Test Scenarios](#test-scenarios)
7. [Test Runner](#test-runner)
8. [Configuration](#configuration)
9. [Reporting](#reporting)
10. [Implementation Prompts](#implementation-prompts)

---

## Overview

The Commander E2E Testing System is a **standalone Elixir application** (`gsmlg_commander_test`) that performs true end-to-end testing by:

1. **Starting a real Commander server** (Management Module)
2. **Starting real Commander agent clients**
3. **Connecting them over actual WebSocket connections**
4. **Executing test scenarios across the full system**
5. **Verifying behavior end-to-end**

This is NOT unit testing. This tests the **complete integrated system** with real network communication, real PTY processes, and real tool execution.

---

## Testing Philosophy

### Why E2E Testing?

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     Unit Tests vs E2E Tests                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Unit Tests:                        E2E Tests (This Module):                 │
│  ────────────                       ─────────────────────────                │
│  • Test isolated functions          • Test complete system                   │
│  • Mock dependencies                • Real server + real clients             │
│  • Fast but limited coverage        • Slower but high confidence             │
│  • Miss integration bugs            • Catch protocol/integration bugs        │
│  • Test implementation              • Test actual user scenarios             │
│                                                                              │
│  This module does E2E testing:                                               │
│                                                                              │
│    ┌─────────────┐     WebSocket      ┌─────────────┐                       │
│    │   Server    │◄──────────────────►│   Agent     │                       │
│    │   (Real)    │    Real Network    │   (Real)    │                       │
│    └─────────────┘                    └─────────────┘                       │
│          │                                   │                               │
│          │                                   │                               │
│          ▼                                   ▼                               │
│    ┌─────────────┐                    ┌─────────────┐                       │
│    │  Sessions   │                    │  Real PTY   │                       │
│    │  Registry   │                    │  Processes  │                       │
│    │  Tokens     │                    │  Real Tools │                       │
│    └─────────────┘                    └─────────────┘                       │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Core Principles

1. **Real Components** - No mocks, use actual server and agent code
2. **Real Network** - Communicate over localhost WebSockets  
3. **Real PTY** - Spawn actual shell processes
4. **Isolated Environment** - Each test run is independent
5. **Comprehensive Scenarios** - Cover all major user flows
6. **Standalone Module** - Can run independently of other tests

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                  gsmlg_commander_test (Standalone Application)               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                           Test Runner                                   │ │
│  │                                                                         │ │
│  │  • Orchestrates entire test execution                                   │ │
│  │  • Manages server + client lifecycle                                    │ │
│  │  • Executes scenarios in sequence or parallel                           │ │
│  │  • Collects results and generates reports                               │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                    │                                         │
│          ┌─────────────────────────┼─────────────────────────┐              │
│          ▼                         ▼                         ▼              │
│  ┌───────────────┐        ┌───────────────┐        ┌───────────────┐       │
│  │ServerManager  │        │ AgentManager  │        │ScenarioRunner │       │
│  │               │        │               │        │               │       │
│  │• Start server │        │• Start agents │        │• Load scenarios│       │
│  │• Health check │        │• Connect all  │        │• Execute steps │       │
│  │• Stop server  │        │• Control PTYs │        │• Assert results│       │
│  └───────┬───────┘        └───────┬───────┘        └───────────────┘       │
│          │                        │                                         │
│          ▼                        ▼                                         │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                        Test Environment                              │   │
│  │                                                                      │   │
│  │   ┌──────────────────────┐         ┌──────────────────────┐         │   │
│  │   │   Commander Server   │         │  Commander Agent(s)  │         │   │
│  │   │   ═══════════════    │         │  ═══════════════════ │         │   │
│  │   │                      │         │                      │         │   │
│  │   │  gsmlg_commander     │◄───────►│  TestAgent (real     │         │   │
│  │   │  (actual app)        │WebSocket│  agent implementation)│         │   │
│  │   │                      │         │                      │         │   │
│  │   │  • Phoenix Channels  │         │  • WebSocket client  │         │   │
│  │   │  • Session GenServer │         │  • PTY via erlexec   │         │   │
│  │   │  • Token Manager     │         │  • Tool handlers     │         │   │
│  │   │  • Registry          │         │  • Heartbeat         │         │   │
│  │   └──────────────────────┘         └──────────────────────┘         │   │
│  │              │                               │                       │   │
│  │              │         localhost:14000       │                       │   │
│  │              └───────────────────────────────┘                       │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Execution Flow

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                          E2E Test Execution Flow                              │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                               │
│  ┌─────────────────────────────────────────────────────────────────────────┐ │
│  │ 1. SETUP                                                                 │ │
│  │    • Create test configuration                                           │ │
│  │    • Generate test tokens                                                │ │
│  │    • Prepare fixtures                                                    │ │
│  └─────────────────────────────────────────────────────────────────────────┘ │
│                                      │                                        │
│                                      ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────────┐ │
│  │ 2. START SERVER                                                          │ │
│  │    • Start gsmlg_commander application on port 14000                     │ │
│  │    • Wait for health check to pass                                       │ │
│  │    • Verify WebSocket endpoint ready                                     │ │
│  └─────────────────────────────────────────────────────────────────────────┘ │
│                                      │                                        │
│                                      ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────────┐ │
│  │ 3. START AGENTS                                                          │ │
│  │    • Start N TestAgent processes (real agent implementation)             │ │
│  │    • Each connects to server via WebSocket                               │ │
│  │    • Wait for all agents authenticated                                   │ │
│  └─────────────────────────────────────────────────────────────────────────┘ │
│                                      │                                        │
│                                      ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────────┐ │
│  │ 4. RUN SCENARIOS                                                         │ │
│  │    For each scenario:                                                    │ │
│  │    • Setup scenario context                                              │ │
│  │    • Execute test steps                                                  │ │
│  │    • Assert expected outcomes                                            │ │
│  │    • Record pass/fail with timing                                        │ │
│  │    • Cleanup scenario resources                                          │ │
│  └─────────────────────────────────────────────────────────────────────────┘ │
│                                      │                                        │
│                                      ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────────┐ │
│  │ 5. TEARDOWN                                                              │ │
│  │    • Stop all agents                                                     │ │
│  │    • Stop server                                                         │ │
│  │    • Verify no resource leaks                                            │ │
│  │    • Generate test report                                                │ │
│  └─────────────────────────────────────────────────────────────────────────┘ │
│                                                                               │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## Module Structure

```
apps/gsmlg_commander_test/
├── mix.exs                              # Standalone application
├── README.md                            # Usage documentation
│
├── config/
│   ├── config.exs                       # Base configuration
│   └── runtime.exs                      # Runtime configuration
│
├── lib/
│   ├── gsmlg_commander_test.ex          # Main entry point
│   │
│   ├── runner/
│   │   ├── test_runner.ex               # Main orchestrator
│   │   ├── server_manager.ex            # Start/stop server
│   │   ├── agent_manager.ex             # Manage test agents
│   │   └── scenario_executor.ex         # Execute scenarios
│   │
│   ├── client/
│   │   ├── test_agent.ex                # Real agent implementation
│   │   ├── agent_connection.ex          # WebSocket connection
│   │   ├── pty_handler.ex               # PTY process management
│   │   └── tool_handler.ex              # Tool request handling
│   │
│   ├── scenarios/
│   │   ├── scenario.ex                  # Scenario behaviour
│   │   ├── connection/                  # Connection scenarios
│   │   │   ├── connect_test.ex
│   │   │   ├── auth_test.ex
│   │   │   └── disconnect_test.ex
│   │   ├── terminal/                    # PTY/Shell scenarios
│   │   │   ├── spawn_pty_test.ex
│   │   │   ├── command_test.ex
│   │   │   └── resize_test.ex
│   │   ├── tools/                       # Tool scenarios
│   │   │   ├── system_info_test.ex
│   │   │   ├── file_browser_test.ex
│   │   │   └── process_list_test.ex
│   │   ├── reconnection/                # Reconnection scenarios
│   │   │   ├── reconnect_test.ex
│   │   │   └── session_preserve_test.ex
│   │   └── stress/                      # Load testing
│   │       ├── many_agents_test.ex
│   │       └── throughput_test.ex
│   │
│   ├── helpers/
│   │   ├── assertions.ex                # Test assertions
│   │   ├── wait.ex                      # Polling utilities
│   │   ├── server_api.ex                # Server HTTP/WS helpers
│   │   ├── fixtures.ex                  # Test data generators
│   │   └── config_generator.ex          # Generate TOML configs for agents
│   │
│   └── reporter/
│       ├── console.ex                   # Console output
│       ├── json.ex                      # JSON report
│       └── html.ex                      # HTML report
│
├── priv/
│   └── templates/
│       └── report.html.eex              # HTML report template
│
└── mix/
    └── tasks/
        └── commander.e2e.ex             # Mix task: mix commander.e2e
```

---

## Test Components

### 1. Server Manager

```elixir
defmodule GSMLG.CommanderTest.Runner.ServerManager do
  @moduledoc """
  Manages Commander server lifecycle for E2E testing.
  
  Starts the actual gsmlg_commander application on a test port,
  waits for it to be ready, and stops it cleanly.
  """
  
  use GenServer
  
  @default_port 14000
  @health_check_timeout 10_000
  
  defstruct [:port, :status, :pid]
  
  ## Public API
  
  @doc "Start the Commander server for testing"
  def start_server(opts \\ []) do
    port = Keyword.get(opts, :port, @default_port)
    
    # Configure and start the Commander application
    configure_for_test(port)
    {:ok, _} = Application.ensure_all_started(:gsmlg_commander)
    
    # Wait for server to be ready
    :ok = wait_for_health_check(port)
    
    {:ok, %{port: port, ws_url: "ws://localhost:#{port}/agent/connect"}}
  end
  
  @doc "Stop the Commander server"
  def stop_server do
    Application.stop(:gsmlg_commander)
    :ok
  end
  
  @doc "Get WebSocket URL for agent connections"
  def get_ws_url(port \\ @default_port) do
    "ws://localhost:#{port}/agent/connect"
  end
  
  @doc "Check server health"
  def health_check(port \\ @default_port) do
    case :httpc.request(:get, {'http://localhost:#{port}/health', []}, [], []) do
      {:ok, {{_, 200, _}, _, _}} -> :ok
      _ -> {:error, :unhealthy}
    end
  end
end
```

### 2. Agent Manager

```elixir
defmodule GSMLG.CommanderTest.Runner.AgentManager do
  @moduledoc """
  Manages multiple test agent instances.
  
  Each agent is a real Commander agent that connects to the server
  over WebSocket, authenticates, and can spawn PTY sessions.
  
  Generates TOML configuration files for each agent using gsmlg_toml.
  """
  
  use GenServer
  
  alias GSMLG.CommanderTest.Helpers.ConfigGenerator
  alias GSMLG.CommanderTest.Client.TestAgent
  
  defstruct [:agents, :supervisor, :config_files]
  
  ## Public API
  
  @doc "Start a test agent with given configuration"
  def start_agent(config) do
    # Generate TOML config file
    {:ok, config_path} = ConfigGenerator.generate_agent_config(config)
    
    # Start agent with config file
    {:ok, pid} = DynamicSupervisor.start_child(
      __MODULE__.Supervisor,
      {TestAgent, config_path}
    )
    
    {:ok, agent_id} = TestAgent.get_id(pid)
    
    # Track config file for cleanup
    GenServer.cast(__MODULE__, {:track_config, agent_id, config_path})
    
    {:ok, agent_id}
  end
  
  @doc "Start multiple agents"
  def start_agents(count, config_fn) when is_function(config_fn, 1) do
    agents = 
      1..count
      |> Enum.map(fn i -> 
        config = config_fn.(i)
        {:ok, id} = start_agent(config)
        id
      end)
    {:ok, agents}
  end
  
  @doc "Stop a specific agent and cleanup its config"
  def stop_agent(agent_id) do
    GenServer.call(__MODULE__, {:stop_agent, agent_id})
  end
  
  @doc "Stop all agents"
  def stop_all_agents() do
    GenServer.call(__MODULE__, :stop_all)
  end
  
  @doc "Wait for agent to reach status"
  def wait_for_status(agent_id, status, timeout \\ 5000)
  
  @doc "Wait for all agents to be connected"
  def wait_all_connected(agent_ids, timeout \\ 10_000)
  
  @doc "Simulate network disconnect"
  def disconnect_agent(agent_id)
  
  @doc "Trigger reconnection"
  def reconnect_agent(agent_id)
  
  @doc "Send data to agent's PTY"
  def send_pty_input(agent_id, pty_id, data)
  
  @doc "Get PTY output"
  def get_pty_output(agent_id, pty_id)
  
  ## Cleanup
  
  def handle_call({:stop_agent, agent_id}, _from, state) do
    # Stop agent process
    case Map.get(state.agents, agent_id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(__MODULE__.Supervisor, pid)
    end
    
    # Cleanup config file
    case Map.get(state.config_files, agent_id) do
      nil -> :ok
      path -> ConfigGenerator.cleanup_config(path)
    end
    
    new_state = %{state | 
      agents: Map.delete(state.agents, agent_id),
      config_files: Map.delete(state.config_files, agent_id)
    }
    
    {:reply, :ok, new_state}
  end
end
```

### 3. Test Agent (Real Implementation)

```elixir
defmodule GSMLG.CommanderTest.Client.TestAgent do
  @moduledoc """
  A real Commander agent for E2E testing.
  
  This is NOT a mock. It implements the actual agent protocol:
  - Loads configuration from TOML (via gsmlg_toml)
  - Connects via WebSocket
  - Authenticates with token
  - Spawns real PTY processes via erlexec
  - Handles tool requests
  - Sends heartbeats
  """
  
  use GenServer
  
  defstruct [
    :id,
    :config,
    :connection,           # WebSocket connection
    :status,               # :disconnected | :connecting | :connected
    :pty_sessions,         # %{pty_id => PTYHandler pid}
    :reconnect_token,
    :subscribers           # Test assertion subscribers
  ]
  
  @capabilities [:shell, :files, :processes, :system_info, :metrics, :logs]
  
  ## Lifecycle
  
  def start_link(config_path) when is_binary(config_path) do
    # Load TOML configuration
    {:ok, config} = GSMLG.TOML.parse_file(config_path)
    start_link(normalize_config(config))
  end
  
  def start_link(config) when is_map(config) do
    GenServer.start_link(__MODULE__, config)
  end
  
  defp normalize_config(toml) do
    %{
      server_url: get_in(toml, ["server", "url"]),
      token: get_in(toml, ["server", "token"]),
      hostname: get_in(toml, ["agent", "hostname"]) || hostname(),
      agent_id: get_in(toml, ["agent", "id"]) || generate_id(),
      heartbeat_interval: get_in(toml, ["connection", "heartbeat_interval"]) || 30,
      capabilities: parse_capabilities(toml["capabilities"] || %{})
    }
  end
  
  defp parse_capabilities(caps) do
    caps
    |> Enum.filter(fn {_k, v} -> v == true end)
    |> Enum.map(fn {k, _v} -> String.to_atom(k) end)
  end
  
  def init(config) do
    state = %__MODULE__{
      id: config.agent_id,
      config: config,
      status: :disconnected,
      pty_sessions: %{},
      subscribers: []
    }
    
    # Auto-connect if server URL provided
    if config[:auto_connect] != false do
      send(self(), :connect)
    end
    
    {:ok, state}
  end
  
  ## Connection
  
  def handle_info(:connect, state) do
    case AgentConnection.connect(state.config.server_url, state.config.token) do
      {:ok, conn} ->
        {:noreply, %{state | connection: conn, status: :connected}}
      {:error, reason} ->
        {:noreply, %{state | status: {:error, reason}}}
    end
  end
  
  ## PTY Operations (called by server via protocol)
  
  def handle_cast({:spawn_pty, pty_id, config}, state) do
    {:ok, pty_pid} = PTYHandler.start_link(%{
      id: pty_id,
      shell: config.shell,
      dimensions: config.dimensions,
      parent: self()
    })
    
    new_sessions = Map.put(state.pty_sessions, pty_id, pty_pid)
    notify_subscribers(state, {:pty_spawned, pty_id})
    
    {:noreply, %{state | pty_sessions: new_sessions}}
  end
  
  def handle_cast({:pty_input, pty_id, data}, state) do
    case Map.get(state.pty_sessions, pty_id) do
      nil -> :ok
      pid -> PTYHandler.send_input(pid, data)
    end
    {:noreply, state}
  end
  
  ## PTY Output (from PTYHandler)
  
  def handle_info({:pty_output, pty_id, data}, state) do
    # Forward to server
    AgentConnection.send_pty_output(state.connection, pty_id, data)
    notify_subscribers(state, {:pty_output, pty_id, data})
    {:noreply, state}
  end
end
```

### 4. PTY Handler

```elixir
defmodule GSMLG.CommanderTest.Client.PTYHandler do
  @moduledoc """
  Manages a real PTY process via erlexec.
  
  Spawns an actual shell process, handles I/O,
  and forwards output to the parent TestAgent.
  """
  
  use GenServer
  
  defstruct [:id, :os_pid, :parent, :output_buffer]
  
  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end
  
  def init(config) do
    # Spawn real PTY via erlexec
    {:ok, pid, os_pid} = :exec.run(
      config.shell,
      [
        :stdin, :stdout, :stderr,
        :pty, :pty_echo,
        :monitor,
        {:env, [{"TERM", "xterm-256color"}]}
      ]
    )
    
    state = %__MODULE__{
      id: config.id,
      os_pid: os_pid,
      parent: config.parent,
      output_buffer: <<>>
    }
    
    {:ok, state}
  end
  
  def send_input(pid, data) do
    GenServer.cast(pid, {:input, data})
  end
  
  def handle_cast({:input, data}, state) do
    :exec.send(state.os_pid, data)
    {:noreply, state}
  end
  
  # Receive output from PTY
  def handle_info({:stdout, os_pid, data}, state) when os_pid == state.os_pid do
    send(state.parent, {:pty_output, state.id, data})
    {:noreply, state}
  end
end
```

---

## Test Scenarios

### Scenario Behaviour

```elixir
defmodule GSMLG.CommanderTest.Scenarios.Scenario do
  @moduledoc """
  Behaviour for E2E test scenarios.
  """
  
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback tags() :: [atom()]
  @callback run(context :: map()) :: :ok | {:error, term()}
  
  defmacro __using__(_opts) do
    quote do
      @behaviour GSMLG.CommanderTest.Scenarios.Scenario
      
      import GSMLG.CommanderTest.Helpers.Assertions
      import GSMLG.CommanderTest.Helpers.Wait
      alias GSMLG.CommanderTest.Runner.{AgentManager, ServerManager}
      alias GSMLG.CommanderTest.Helpers.ServerAPI
    end
  end
end
```

### Scenario List

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            E2E Test Scenarios                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  CONNECTION SCENARIOS (scenarios/connection/)                                │
│  ─────────────────────────────────────────────                               │
│  • connect_test.ex                                                           │
│    - agent_connects_with_valid_token                                         │
│    - agent_rejected_with_invalid_token                                       │
│    - agent_rejected_with_expired_token                                       │
│    - agent_rejected_with_revoked_token                                       │
│                                                                              │
│  • auth_test.ex                                                              │
│    - capabilities_enforced_from_token                                        │
│    - auto_tags_applied_from_token                                            │
│    - limited_token_restricts_access                                          │
│                                                                              │
│  • disconnect_test.ex                                                        │
│    - graceful_disconnect_cleans_up                                           │
│    - heartbeat_keeps_connection_alive                                        │
│    - timeout_on_missing_heartbeat                                            │
│                                                                              │
│  TERMINAL SCENARIOS (scenarios/terminal/)                                    │
│  ─────────────────────────────────────────                                   │
│  • spawn_pty_test.ex                                                         │
│    - spawn_pty_session_succeeds                                              │
│    - spawn_multiple_pty_sessions                                             │
│    - spawn_pty_without_capability_fails                                      │
│                                                                              │
│  • command_test.ex                                                           │
│    - send_command_receive_output                                             │
│    - interactive_command_works                                               │
│    - binary_output_handled                                                   │
│    - large_output_streaming                                                  │
│                                                                              │
│  • resize_test.ex                                                            │
│    - pty_resize_updates_dimensions                                           │
│    - resize_signal_received_by_process                                       │
│                                                                              │
│  TOOLS SCENARIOS (scenarios/tools/)                                          │
│  ───────────────────────────────────                                         │
│  • system_info_test.ex                                                       │
│    - get_system_info_returns_data                                            │
│    - system_info_without_capability_fails                                    │
│                                                                              │
│  • file_browser_test.ex                                                      │
│    - list_directory_returns_entries                                          │
│    - read_file_returns_content                                               │
│    - file_access_respects_permissions                                        │
│                                                                              │
│  • process_list_test.ex                                                      │
│    - list_processes_returns_data                                             │
│    - process_info_returns_details                                            │
│                                                                              │
│  RECONNECTION SCENARIOS (scenarios/reconnection/)                            │
│  ─────────────────────────────────────────────────                           │
│  • reconnect_test.ex                                                         │
│    - reconnect_within_grace_period_succeeds                                  │
│    - reconnect_after_grace_period_fails                                      │
│    - reconnect_requires_token                                                │
│                                                                              │
│  • session_preserve_test.ex                                                  │
│    - pty_preserved_on_reconnect                                              │
│    - output_buffered_during_disconnect                                       │
│    - environment_state_preserved                                             │
│                                                                              │
│  STRESS SCENARIOS (scenarios/stress/) [tagged :stress]                       │
│  ───────────────────────────────────────────────────                         │
│  • many_agents_test.ex                                                       │
│    - fifty_agents_connect_simultaneously                                     │
│    - agents_isolated_from_each_other                                         │
│                                                                              │
│  • throughput_test.ex                                                        │
│    - high_volume_pty_output                                                  │
│    - rapid_connect_disconnect_cycles                                         │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Example Scenario

```elixir
defmodule GSMLG.CommanderTest.Scenarios.Terminal.CommandTest do
  @moduledoc """
  E2E test: Send commands to PTY and verify output.
  """
  
  use GSMLG.CommanderTest.Scenarios.Scenario
  
  @impl true
  def name, do: "send_command_receive_output"
  
  @impl true
  def description, do: "Send a command to PTY and verify output received"
  
  @impl true
  def tags, do: [:terminal, :core]
  
  @impl true
  def run(context) do
    # 1. Start an agent
    {:ok, agent_id} = AgentManager.start_agent(%{
      hostname: "test-cmd-agent",
      token: context.test_token,
      capabilities: [:shell]
    })
    
    # 2. Wait for connection
    :ok = AgentManager.wait_for_status(agent_id, :connected, 5000)
    
    # 3. Spawn PTY via server
    {:ok, pty_id} = ServerAPI.spawn_pty(agent_id, %{shell: "/bin/bash"})
    
    # 4. Wait for PTY ready
    :ok = wait_until(fn ->
      {:ok, status} = ServerAPI.get_pty_status(agent_id, pty_id)
      status == :ready
    end, timeout: 5000)
    
    # 5. Send command
    :ok = ServerAPI.send_pty_input(agent_id, pty_id, "echo 'E2E_TEST_123'\n")
    
    # 6. Wait for output
    output = wait_for_output(agent_id, pty_id, 
      containing: "E2E_TEST_123", 
      timeout: 5000
    )
    
    # 7. Assert
    assert_contains(output, "E2E_TEST_123")
    
    # 8. Cleanup
    :ok = AgentManager.stop_agent(agent_id)
    
    :ok
  end
end
```

### Reconnection Scenario Example

```elixir
defmodule GSMLG.CommanderTest.Scenarios.Reconnection.SessionPreserveTest do
  @moduledoc """
  E2E test: PTY session preserved across reconnection.
  """
  
  use GSMLG.CommanderTest.Scenarios.Scenario
  
  @impl true
  def name, do: "pty_preserved_on_reconnect"
  
  @impl true
  def description, do: "PTY session survives agent reconnection"
  
  @impl true
  def tags, do: [:reconnection, :pty]
  
  @impl true
  def run(context) do
    # 1. Start agent and spawn PTY
    {:ok, agent_id} = AgentManager.start_agent(%{
      hostname: "reconnect-agent",
      token: context.test_token
    })
    :ok = AgentManager.wait_for_status(agent_id, :connected)
    
    {:ok, pty_id} = ServerAPI.spawn_pty(agent_id, %{shell: "/bin/bash"})
    wait_for_pty_ready(agent_id, pty_id)
    
    # 2. Set state in PTY
    ServerAPI.send_pty_input(agent_id, pty_id, "export TEST_VAR='preserved'\n")
    :timer.sleep(500)
    
    # 3. Disconnect agent (simulate network failure)
    :ok = AgentManager.disconnect_agent(agent_id)
    
    # 4. Verify server shows disconnected
    :ok = wait_until(fn ->
      {:ok, session} = ServerAPI.get_session(agent_id)
      session.status == :disconnected
    end)
    
    # 5. Verify PTY still exists on server
    {:ok, session} = ServerAPI.get_session(agent_id)
    assert session.pty_sessions[pty_id] != nil
    
    # 6. Reconnect within grace period
    :ok = AgentManager.reconnect_agent(agent_id)
    :ok = AgentManager.wait_for_status(agent_id, :connected)
    
    # 7. Verify state preserved
    ServerAPI.send_pty_input(agent_id, pty_id, "echo $TEST_VAR\n")
    output = wait_for_output(agent_id, pty_id, containing: "preserved")
    assert_contains(output, "preserved")
    
    # 8. Cleanup
    AgentManager.stop_agent(agent_id)
    
    :ok
  end
end
```

---

## Test Runner

```elixir
defmodule GSMLG.CommanderTest.Runner.TestRunner do
  @moduledoc """
  Main E2E test orchestrator.
  
  ## Usage
  
      # Run all tests
      GSMLG.CommanderTest.run()
      
      # Run specific tags
      GSMLG.CommanderTest.run(tags: [:terminal])
      
      # Run with options
      GSMLG.CommanderTest.run(
        tags: [:core],
        parallel: false,
        timeout: 60_000
      )
  """
  
  def run(opts \\ []) do
    IO.puts("\n🚀 Starting Commander E2E Tests\n")
    
    # 1. Setup
    config = build_config(opts)
    
    # 2. Start server
    IO.puts("Starting Commander server...")
    {:ok, server} = ServerManager.start_server(port: config.port)
    IO.puts("✓ Server started on port #{config.port}\n")
    
    # 3. Create test token
    {:ok, token} = create_test_token(server)
    context = %{server: server, test_token: token}
    
    # 4. Discover and run scenarios
    scenarios = discover_scenarios(opts[:tags])
    IO.puts("Found #{length(scenarios)} scenarios to run\n")
    
    results = Enum.map(scenarios, fn scenario ->
      run_scenario(scenario, context, config)
    end)
    
    # 5. Stop server
    IO.puts("\nStopping server...")
    ServerManager.stop_server()
    
    # 6. Report results
    report_results(results)
    
    {:ok, summarize(results)}
  end
  
  defp run_scenario(scenario, context, config) do
    IO.write("  #{scenario.name}... ")
    start = System.monotonic_time(:millisecond)
    
    result = try do
      case scenario.run(context) do
        :ok -> :passed
        {:error, reason} -> {:failed, reason}
      end
    catch
      kind, reason ->
        {:failed, {kind, reason, __STACKTRACE__}}
    end
    
    duration = System.monotonic_time(:millisecond) - start
    
    case result do
      :passed ->
        IO.puts("✅ (#{duration}ms)")
      {:failed, reason} ->
        IO.puts("❌ (#{duration}ms)")
        IO.puts("    Error: #{inspect(reason)}")
    end
    
    %{scenario: scenario.name, result: result, duration: duration}
  end
end
```

### CLI Task

```elixir
defmodule Mix.Tasks.Commander.E2e do
  @moduledoc """
  Run Commander E2E tests.
  
  ## Usage
  
      mix commander.e2e                    # Run all tests
      mix commander.e2e --tags terminal    # Run terminal tests
      mix commander.e2e --tags core        # Run core tests
      mix commander.e2e --list             # List all scenarios
      mix commander.e2e --scenario name    # Run specific scenario
  """
  
  use Mix.Task
  
  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args,
      strict: [
        tags: :string,
        scenario: :string,
        list: :boolean,
        timeout: :integer,
        verbose: :boolean
      ]
    )
    
    # Start applications
    Application.ensure_all_started(:gsmlg_commander_test)
    
    cond do
      opts[:list] ->
        list_scenarios()
      
      opts[:scenario] ->
        run_single(opts[:scenario])
      
      true ->
        tags = if opts[:tags], do: String.split(opts[:tags], ",") |> Enum.map(&String.to_atom/1)
        GSMLG.CommanderTest.run(tags: tags)
    end
  end
end
```

---

## Configuration

```elixir
# config/config.exs
import Config

config :gsmlg_commander_test,
  # Server settings
  server_port: 14000,
  
  # Timeouts (faster for testing)
  connect_timeout: 5_000,
  scenario_timeout: 30_000,
  
  # Test configuration for server
  server_config: [
    idle_timeout: :timer.seconds(30),
    reconnect_grace_period: :timer.seconds(10),
    heartbeat_interval: :timer.seconds(5)
  ],
  
  # Reporters
  reporters: [:console],
  
  # Stress test limits
  stress: [
    max_agents: 100,
    max_duration: :timer.minutes(5)
  ]
```

### Test Agent Configuration (TOML)

Test agents use the same TOML configuration format as production agents.
The test framework generates temporary config files:

```toml
# Generated test config (e.g., /tmp/commander_test_agent_1.toml)

[server]
url = "ws://localhost:14000/agent/connect"
token = "test_token_abc123"

[agent]
hostname = "test-agent-1"
id = "test-agent-001"

[connection]
heartbeat_interval = 5           # Faster for testing
reconnect_initial_delay = 1
reconnect_max_delay = 10

[pty]
default_shell = "/bin/bash"
default_term = "xterm-256color"
max_sessions = 5

[capabilities]
shell = true
files = true
processes = true
system_info = true
metrics = true
logs = true
```

The `AgentManager` generates these configs dynamically:

```elixir
defmodule GSMLG.CommanderTest.Helpers.ConfigGenerator do
  @moduledoc "Generate TOML configs for test agents"
  
  def generate_agent_config(opts) do
    config = """
    [server]
    url = "#{opts.server_url}"
    token = "#{opts.token}"
    
    [agent]
    hostname = "#{opts.hostname}"
    id = "#{opts.agent_id}"
    
    [connection]
    heartbeat_interval = 5
    reconnect_initial_delay = 1
    reconnect_max_delay = 10
    
    [capabilities]
    #{Enum.map_join(opts.capabilities, "\n", &"#{&1} = true")}
    """
    
    path = Path.join(System.tmp_dir!(), "commander_test_#{opts.agent_id}.toml")
    File.write!(path, config)
    {:ok, path}
  end
end
```

---

## Reporting

### Console Output

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     Commander E2E Test Results                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  🚀 Starting Commander E2E Tests                                            │
│                                                                              │
│  Starting Commander server...                                                │
│  ✓ Server started on port 14000                                             │
│                                                                              │
│  Found 18 scenarios to run                                                   │
│                                                                              │
│  CONNECTION                                                                  │
│    agent_connects_with_valid_token............... ✅ (1234ms)               │
│    agent_rejected_with_invalid_token............. ✅ (523ms)                │
│    agent_rejected_with_expired_token............. ✅ (498ms)                │
│                                                                              │
│  TERMINAL                                                                    │
│    spawn_pty_session_succeeds.................... ✅ (2341ms)               │
│    send_command_receive_output................... ✅ (3102ms)               │
│    interactive_command_works..................... ❌ (5000ms)               │
│      Error: timeout waiting for output                                       │
│    pty_resize_updates_dimensions................. ✅ (1823ms)               │
│                                                                              │
│  RECONNECTION                                                                │
│    pty_preserved_on_reconnect.................... ✅ (8234ms)               │
│    output_buffered_during_disconnect............. ✅ (7891ms)               │
│                                                                              │
│  Stopping server...                                                          │
│                                                                              │
│  ═══════════════════════════════════════════════════════════════════════    │
│                                                                              │
│  SUMMARY                                                                     │
│  ────────                                                                    │
│  Total:    18                                                                │
│  Passed:   17 (94.4%)                                                        │
│  Failed:   1  (5.6%)                                                         │
│  Duration: 45.2s                                                             │
│                                                                              │
│  Failed:                                                                     │
│    • terminal/interactive_command_works                                      │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Implementation Prompts

### Prompt 1: Test Module Foundation

```
Project: Create gsmlg_commander_test as new app in gsmlg_umbrella

Create the standalone E2E testing application structure:

1. Create new umbrella app:
   cd apps && mix new gsmlg_commander_test --sup
   
2. Configure mix.exs:
   - deps: {:gsmlg_commander, in_umbrella: true}, {:gsmlg_toml, in_umbrella: true}, {:http_web_socket, "~> 0.11.0"}
   - Add escript configuration for CLI

3. Create lib/gsmlg_commander_test.ex:
   - run/1 function as main entry point
   - list_scenarios/0 to list available scenarios
   - Delegates to TestRunner

4. Create lib/gsmlg_commander_test/application.ex:
   - Supervision tree with:
     - Registry for tracking resources
     - DynamicSupervisor for test agents

5. Create mix/tasks/commander.e2e.ex:
   - Mix task: mix commander.e2e [options]
   - Options: --tags, --scenario, --list, --timeout

6. Create config/config.exs:
   - Server port
   - Timeout settings
   - Reporter configuration

Deliverable: Running `mix commander.e2e --list` should work (empty list ok)
```

---

### Prompt 2: Server Manager

```
Project: gsmlg_commander_test
Depends on: Prompt 1

Create the Server Manager that controls the Commander server lifecycle:

1. lib/runner/server_manager.ex - GenServer:

   start_server(opts):
   - Take port from opts (default 14000)
   - Set Application env for gsmlg_commander with test config:
     - Fast timeouts (30s idle, 10s grace, 5s heartbeat)
     - Test database configuration
   - Call Application.ensure_all_started(:gsmlg_commander)
   - Perform health check loop until ready
   - Return {:ok, %{port: port, ws_url: url}}
   
   stop_server():
   - Application.stop(:gsmlg_commander)
   - Verify clean shutdown
   - Return :ok
   
   health_check(port):
   - HTTP GET to localhost:port/health
   - Return :ok | {:error, reason}
   
   get_ws_url():
   - Return WebSocket URL for agents

2. Add health endpoint to gsmlg_commander if not exists:
   - GET /health returns 200 OK when ready

3. Test: Start server, verify health check, stop server
```

---

### Prompt 3: Test Agent Implementation

```
Project: gsmlg_commander_test
Depends on: Prompts 1-2

Create a real Commander agent for testing:

1. lib/helpers/config_generator.ex:
   
   Generate TOML configuration files for test agents:
   
   generate_agent_config(opts):
   - opts: %{server_url, token, hostname, agent_id, capabilities}
   - Generate TOML content with [server], [agent], [connection], [capabilities]
   - Write to temp file
   - Return {:ok, path}
   
   cleanup_config(path):
   - Delete temp config file

2. lib/client/test_agent.ex - GenServer:
   
   State:
   - id, config, connection (WebSocket), status
   - pty_sessions: %{pty_id => PTYHandler pid}
   - subscribers: [pid] for test event notifications
   
   start_link(config_path) when is_binary:
   - Load TOML via GSMLG.TOML.parse_file(config_path)
   - Normalize to internal config map
   - Call start_link with config map
   
   start_link(config) when is_map:
   - Use config directly (for programmatic testing)
   
   Connection flow:
   - Connect WebSocket to server
   - Send AUTH_REQUEST with token
   - Handle AUTH_RESPONSE
   - Start heartbeat timer
   - Transition to :connected
   
   PTY handling:
   - On PTY_SPAWN from server: start PTYHandler
   - On PTY_INPUT: forward to PTYHandler
   - On PTY_RESIZE: call PTYHandler.resize
   - Forward PTY output to server as PTY_OUTPUT

3. lib/client/pty_handler.ex - GenServer:
   
   - Spawn real shell via :exec.run with [:pty, :stdin, :stdout]
   - send_input/2: forward to PTY
   - resize/3: update PTY dimensions
   - Forward stdout to parent TestAgent

4. lib/client/agent_connection.ex:
   
   - WebSockex-based WebSocket client
   - connect/2: establish connection
   - send_frame/2: send protocol frames
   - Handle incoming frames, dispatch to TestAgent

Test: Agent loads TOML config, connects to server, authenticates, spawns PTY
```

---

### Prompt 4: Agent Manager

```
Project: gsmlg_commander_test
Depends on: Prompts 1-3

Create the Agent Manager for controlling test agents:

1. lib/runner/agent_manager.ex - GenServer:
   
   State:
   - agents: %{id => %{pid, status, config}}
   - supervisor: DynamicSupervisor ref
   
   start_agent(config):
   - Start TestAgent under DynamicSupervisor
   - Track in state
   - Return {:ok, agent_id}
   
   start_agents(count, config_fn):
   - Start N agents with config_fn.(index) for each
   - Return {:ok, [agent_ids]}
   
   stop_agent(agent_id):
   - Terminate TestAgent process
   - Remove from tracking
   
   stop_all_agents():
   - Stop all tracked agents
   
   wait_for_status(agent_id, status, timeout):
   - Poll agent status
   - Return :ok when reached or {:error, :timeout}
   
   disconnect_agent(agent_id):
   - Tell agent to close WebSocket
   - Agent should remain in disconnected state
   
   reconnect_agent(agent_id):
   - Tell agent to reconnect with saved token

2. Add to application supervision tree

Test: Start 3 agents, verify all connect, stop all
```

---

### Prompt 5: Scenario Framework

```
Project: gsmlg_commander_test
Depends on: Prompts 1-4

Create the scenario execution framework:

1. lib/scenarios/scenario.ex:
   
   @callback name() :: String.t()
   @callback description() :: String.t()
   @callback tags() :: [atom()]
   @callback run(context) :: :ok | {:error, term()}
   
   __using__ macro:
   - Import assertions and helpers
   - Alias managers

2. lib/helpers/assertions.ex:
   
   - assert_connected(agent_id)
   - assert_disconnected(agent_id)
   - assert_pty_exists(agent_id, pty_id)
   - assert_contains(output, pattern)
   - assert_error(result, type)

3. lib/helpers/wait.ex:
   
   - wait_until(fun, opts) - poll until true
   - wait_for_status(agent_id, status, timeout)
   - wait_for_output(agent_id, pty_id, opts)

4. lib/helpers/server_api.ex:
   
   HTTP helpers to interact with server:
   - get_session(agent_id)
   - list_sessions()
   - spawn_pty(agent_id, config)
   - send_pty_input(agent_id, pty_id, data)
   - get_pty_status(agent_id, pty_id)

5. lib/runner/scenario_executor.ex:
   
   - execute(scenario_module, context) -> result
   - Handle timeout
   - Capture errors
   - Return %{name, result, duration}
```

---

### Prompt 6: Connection Scenarios

```
Project: gsmlg_commander_test
Depends on: Prompts 1-5

Create connection and authentication test scenarios:

1. lib/scenarios/connection/connect_test.ex:
   
   AgentConnectsWithValidToken:
   - Start agent with valid token
   - Wait for :connected
   - Verify appears in server session list
   
   AgentRejectedWithInvalidToken:
   - Start agent with "invalid_token_xxx"
   - Assert connection fails
   - Assert error reason is :invalid_token
   
   AgentRejectedWithExpiredToken:
   - Create expired token via server API
   - Start agent with expired token
   - Assert connection fails

2. lib/scenarios/connection/auth_test.ex:
   
   CapabilitiesEnforcedFromToken:
   - Create token with only [:system_info]
   - Connect agent
   - Try to spawn PTY
   - Assert fails with capability error
   
   AutoTagsAppliedFromToken:
   - Create token with auto_tags: ["test", "e2e"]
   - Connect agent
   - Get session from server
   - Assert tags present

3. lib/scenarios/connection/disconnect_test.ex:
   
   GracefulDisconnectCleansUp:
   - Connect agent
   - Call disconnect
   - Verify session removed from server
```

---

### Prompt 7: Terminal Scenarios

```
Project: gsmlg_commander_test
Depends on: Prompts 1-6

Create PTY/terminal test scenarios:

1. lib/scenarios/terminal/spawn_pty_test.ex:
   
   SpawnPTYSessionSucceeds:
   - Connect agent
   - Call ServerAPI.spawn_pty
   - Wait for PTY ready
   - Verify PTY in session
   
   SpawnMultiplePTYSessions:
   - Connect agent
   - Spawn 3 PTYs
   - Verify all exist
   - Send different commands to each
   - Verify outputs don't cross

2. lib/scenarios/terminal/command_test.ex:
   
   SendCommandReceiveOutput:
   - Connect, spawn PTY
   - Send "echo 'TEST_OUTPUT'\n"
   - Wait for output containing "TEST_OUTPUT"
   - Assert found
   
   InteractiveCommandWorks:
   - Spawn PTY
   - Run "cat" (waits for input)
   - Send "hello\n"
   - Verify "hello" echoed
   - Send Ctrl+D
   - Verify cat exits
   
   LargeOutputStreaming:
   - Spawn PTY
   - Run "seq 1 1000"
   - Collect all output
   - Verify 1000 lines received

3. lib/scenarios/terminal/resize_test.ex:
   
   PTYResizeUpdatesDimensions:
   - Spawn PTY at 80x24
   - Send resize to 120x40
   - Run "tput cols && tput lines"
   - Verify 120 and 40 in output
```

---

### Prompt 8: Reconnection Scenarios

```
Project: gsmlg_commander_test
Depends on: Prompts 1-7

Create reconnection test scenarios:

1. lib/scenarios/reconnection/reconnect_test.ex:
   
   ReconnectWithinGracePeriodSucceeds:
   - Connect agent
   - Disconnect (simulate network failure)
   - Wait 2 seconds (within 10s grace)
   - Reconnect
   - Verify session restored
   
   ReconnectAfterGracePeriodFails:
   - Connect agent
   - Disconnect
   - Wait 12 seconds (past 10s grace)
   - Try reconnect
   - Verify fails

2. lib/scenarios/reconnection/session_preserve_test.ex:
   
   PTYPreservedOnReconnect:
   - Connect, spawn PTY
   - Set "export VAR=test"
   - Disconnect
   - Verify PTY still on server
   - Reconnect
   - Echo $VAR
   - Verify "test" in output
   
   OutputBufferedDuringDisconnect:
   - Connect, spawn PTY
   - Start "seq 1 100" (slow output)
   - Disconnect mid-stream
   - Wait 1 second
   - Reconnect
   - Verify buffered output delivered
   - Verify no gaps in sequence
```

---

### Prompt 9: Test Runner

```
Project: gsmlg_commander_test
Depends on: Prompts 1-8

Create the main test runner:

1. lib/runner/test_runner.ex:
   
   run(opts):
   - Build config from opts
   - Start server via ServerManager
   - Create test token
   - Discover scenarios (filter by tags if specified)
   - Execute each scenario with ScenarioExecutor
   - Collect results
   - Stop server
   - Generate report
   - Return summary
   
   discover_scenarios(tags):
   - Find all scenario modules
   - Filter by tags if provided
   - Return [module]
   
   Private:
   - build_config/1
   - create_test_token/1
   - summarize/1

2. lib/helpers/fixtures.ex:
   
   create_test_token(server, opts):
   - Call server API to create token
   - Return token string
   
   default_capabilities():
   - [:shell, :files, :processes, :system_info]

3. Update mix task to use TestRunner
```

---

### Prompt 10: Reporters and Polish

```
Project: gsmlg_commander_test
Depends on: Prompts 1-9

Create reporters and finalize:

1. lib/reporter/console.ex:
   
   - start_run() - print header
   - scenario_result(result) - print ✅/❌ with timing
   - failure_detail(result) - print error info
   - summary(results) - print totals
   - end_run() - print footer

2. lib/reporter/json.ex:
   
   - generate_report(results) -> map
   - write_report(report, path)
   
   Report structure:
   - meta: timestamps, config
   - scenarios: [{name, status, duration, error}]
   - summary: {total, passed, failed}

3. Update TestRunner:
   - Initialize reporters
   - Call reporter hooks during execution
   - Generate final reports

4. Documentation:
   - README.md with:
     - How to run tests
     - How to add scenarios
     - Configuration options
     - CI integration example

5. Final integration test:
   - Run full test suite
   - Verify reports generated
   - Verify exit code reflects pass/fail
```

---

*End of Commander E2E Testing System Design Document*
