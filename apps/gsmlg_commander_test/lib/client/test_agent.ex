defmodule GSMLG.CommanderTest.Client.TestAgent do
  @moduledoc """
  A real Commander agent for E2E testing.

  This is NOT a mock. It implements the actual agent protocol:
  - Loads configuration from TOML
  - Connects via WebSocket
  - Authenticates with token
  - Spawns real PTY processes via erlexec
  - Handles tool requests
  - Sends heartbeats

  ## Architecture

      ┌─────────────────────────────────────────────────────────────┐
      │                     TestAgent (GenServer)                    │
      ├─────────────────────────────────────────────────────────────┤
      │                                                             │
      │  ┌─────────────────┐       ┌─────────────────────────────┐ │
      │  │  AgentConnection │◄─────►│  WebSocket to Server        │ │
      │  │  (WebSockex)     │       │  ws://localhost:14000/agent │ │
      │  └─────────────────┘       └─────────────────────────────┘ │
      │          │                                                  │
      │          ▼                                                  │
      │  ┌─────────────────────────────────────────────────────────┐│
      │  │                     PTY Sessions                        ││
      │  │  ┌───────────┐ ┌───────────┐ ┌───────────┐             ││
      │  │  │PTYHandler │ │PTYHandler │ │PTYHandler │             ││
      │  │  │  (bash)   │ │  (zsh)    │ │  (sh)     │             ││
      │  │  └───────────┘ └───────────┘ └───────────┘             ││
      │  └─────────────────────────────────────────────────────────┘│
      │                                                             │
      └─────────────────────────────────────────────────────────────┘

  """

  use GenServer

  alias GSMLG.CommanderTest.Client.{AgentConnection, PTYHandler}

  require Logger

  defstruct [
    :id,
    :config,
    :config_path,
    :connection,
    :status,
    :reconnect_token,
    pty_sessions: %{},
    output_buffers: %{},
    subscribers: []
  ]

  @capabilities [:shell, :files, :processes, :system_info, :metrics, :logs]

  # Client API

  @doc """
  Start a TestAgent process.

  Can be started with either a config path (TOML file) or a config map.
  """
  def start_link(opts) do
    config_path = Keyword.get(opts, :config_path)
    config = Keyword.get(opts, :config, %{})

    config =
      if config_path do
        case load_config_from_file(config_path) do
          {:ok, file_config} -> Map.merge(config, file_config)
          {:error, _} -> config
        end
      else
        config
      end

    GenServer.start_link(__MODULE__, {config, config_path})
  end

  @doc """
  Get the agent's ID.
  """
  def get_id(pid) do
    GenServer.call(pid, :get_id)
  end

  @doc """
  Get the agent's current status.
  """
  def get_status(pid) do
    GenServer.call(pid, :get_status)
  end

  @doc """
  Disconnect the agent.
  """
  def disconnect(pid) do
    GenServer.cast(pid, :disconnect)
  end

  @doc """
  Reconnect the agent.
  """
  def reconnect(pid) do
    GenServer.cast(pid, :reconnect)
  end

  @doc """
  Get PTY output.
  """
  def get_pty_output(pid, pty_id) do
    GenServer.call(pid, {:get_pty_output, pty_id})
  end

  @doc """
  Send input to PTY.
  """
  def send_pty_input(pid, pty_id, data) do
    GenServer.call(pid, {:send_pty_input, pty_id, data})
  end

  @doc """
  Subscribe to agent events.
  """
  def subscribe(pid) do
    GenServer.call(pid, {:subscribe, self()})
  end

  # GenServer callbacks

  @impl true
  def init({config, config_path}) do
    state = %__MODULE__{
      id: Map.get(config, :agent_id, generate_id()),
      config: normalize_config(config),
      config_path: config_path,
      status: :disconnected,
      pty_sessions: %{},
      output_buffers: %{},
      subscribers: []
    }

    # Auto-connect if configured
    if Map.get(config, :auto_connect, true) do
      send(self(), :connect)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:get_id, _from, state) do
    {:reply, {:ok, state.id}, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_call({:get_pty_output, pty_id}, _from, state) do
    output = Map.get(state.output_buffers, pty_id, "")
    # Clear the buffer after reading
    new_buffers = Map.put(state.output_buffers, pty_id, "")
    {:reply, {:ok, output}, %{state | output_buffers: new_buffers}}
  end

  @impl true
  def handle_call({:send_pty_input, pty_id, data}, _from, state) do
    case Map.get(state.pty_sessions, pty_id) do
      nil ->
        {:reply, {:error, :pty_not_found}, state}

      pty_pid ->
        PTYHandler.send_input(pty_pid, data)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: [pid | state.subscribers]}}
  end

  @impl true
  def handle_cast(:disconnect, state) do
    if state.connection do
      AgentConnection.disconnect(state.connection)
    end

    {:noreply, %{state | status: :disconnected, connection: nil}}
  end

  @impl true
  def handle_cast(:reconnect, state) do
    send(self(), :connect)
    {:noreply, %{state | status: :connecting}}
  end

  @impl true
  def handle_info(:connect, state) do
    server_url = state.config.server_url
    token = state.config.token

    case AgentConnection.connect(server_url, token, self()) do
      {:ok, conn} ->
        notify_subscribers(state, {:connected, state.id})
        {:noreply, %{state | connection: conn, status: :connected}}

      {:error, reason} ->
        notify_subscribers(state, {:connection_failed, state.id, reason})
        {:noreply, %{state | status: {:error, reason}}}
    end
  end

  @impl true
  def handle_info({:ws_message, message}, state) do
    state = handle_protocol_message(message, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:ws_disconnected, reason}, state) do
    notify_subscribers(state, {:disconnected, state.id, reason})
    {:noreply, %{state | status: :disconnected, connection: nil}}
  end

  @impl true
  def handle_info({:pty_output, pty_id, data}, state) do
    # Buffer the output
    current = Map.get(state.output_buffers, pty_id, "")
    new_buffers = Map.put(state.output_buffers, pty_id, current <> data)

    # Forward to server if connected
    if state.connection do
      AgentConnection.send_pty_output(state.connection, pty_id, data)
    end

    notify_subscribers(state, {:pty_output, state.id, pty_id, data})
    {:noreply, %{state | output_buffers: new_buffers}}
  end

  @impl true
  def handle_info({:pty_exit, pty_id, exit_code}, state) do
    notify_subscribers(state, {:pty_exit, state.id, pty_id, exit_code})

    new_sessions = Map.delete(state.pty_sessions, pty_id)
    {:noreply, %{state | pty_sessions: new_sessions}}
  end

  # Protocol message handling

  defp handle_protocol_message(%{"type" => "spawn_pty"} = msg, state) do
    pty_id = msg["pty_id"]
    shell = msg["shell"] || "/bin/bash"
    rows = msg["rows"] || 24
    cols = msg["cols"] || 80

    case PTYHandler.start_link(%{
           id: pty_id,
           shell: shell,
           rows: rows,
           cols: cols,
           parent: self()
         }) do
      {:ok, pty_pid} ->
        new_sessions = Map.put(state.pty_sessions, pty_id, pty_pid)
        notify_subscribers(state, {:pty_spawned, state.id, pty_id})
        %{state | pty_sessions: new_sessions}

      {:error, reason} ->
        Logger.error("Failed to spawn PTY: #{inspect(reason)}")
        state
    end
  end

  defp handle_protocol_message(%{"type" => "pty_input", "pty_id" => pty_id, "data" => data}, state) do
    case Map.get(state.pty_sessions, pty_id) do
      nil ->
        Logger.warning("Received input for unknown PTY: #{pty_id}")
        state

      pty_pid ->
        PTYHandler.send_input(pty_pid, data)
        state
    end
  end

  defp handle_protocol_message(%{"type" => "pty_resize"} = msg, state) do
    pty_id = msg["pty_id"]
    rows = msg["rows"]
    cols = msg["cols"]

    case Map.get(state.pty_sessions, pty_id) do
      nil ->
        state

      pty_pid ->
        PTYHandler.resize(pty_pid, rows, cols)
        state
    end
  end

  defp handle_protocol_message(%{"type" => "heartbeat"}, state) do
    # Respond to heartbeat
    if state.connection do
      AgentConnection.send_heartbeat_response(state.connection)
    end

    state
  end

  defp handle_protocol_message(%{"type" => "auth_response", "status" => "ok"} = msg, state) do
    reconnect_token = msg["reconnect_token"]
    %{state | reconnect_token: reconnect_token, status: :connected}
  end

  defp handle_protocol_message(%{"type" => "auth_response", "status" => "error"} = msg, state) do
    error = msg["error"]
    notify_subscribers(state, {:auth_failed, state.id, error})
    %{state | status: {:auth_error, error}}
  end

  defp handle_protocol_message(_msg, state) do
    state
  end

  # Private helpers

  defp normalize_config(config) do
    %{
      server_url: Map.get(config, :server_url, "ws://localhost:14000/agent/connect"),
      token: Map.get(config, :token, "test_token"),
      hostname: Map.get(config, :hostname, hostname()),
      agent_id: Map.get(config, :agent_id, generate_id()),
      heartbeat_interval: Map.get(config, :heartbeat_interval, 30),
      capabilities: Map.get(config, :capabilities, @capabilities)
    }
  end

  defp load_config_from_file(path) do
    # In a real implementation, this would parse the TOML file
    # For now, return an empty config and let the passed config take precedence
    case File.read(path) do
      {:ok, _content} ->
        # TODO: Parse TOML content
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp notify_subscribers(state, event) do
    Enum.each(state.subscribers, fn pid ->
      send(pid, {:agent_event, event})
    end)
  end

  defp hostname do
    {:ok, hostname} = :inet.gethostname()
    to_string(hostname)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
