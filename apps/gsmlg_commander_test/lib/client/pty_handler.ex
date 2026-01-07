defmodule GSMLG.CommanderTest.Client.PTYHandler do
  @moduledoc """
  Manages a real PTY process via erlexec.

  Spawns an actual shell process with PTY, handles I/O,
  and forwards output to the parent TestAgent.

  ## Architecture

      ┌─────────────────────────────────────────────────────────────┐
      │                     PTYHandler (GenServer)                   │
      ├─────────────────────────────────────────────────────────────┤
      │                                                             │
      │  ┌─────────────────┐       ┌─────────────────────────────┐ │
      │  │    erlexec      │       │    Shell Process            │ │
      │  │    (Port)       │◄─────►│    /bin/bash                │ │
      │  └─────────────────┘       └─────────────────────────────┘ │
      │          │                                                  │
      │          │ stdout/stderr                                    │
      │          ▼                                                  │
      │  ┌─────────────────────────────────────────────────────────┐│
      │  │                  Parent TestAgent                       ││
      │  │                  {:pty_output, id, data}                ││
      │  └─────────────────────────────────────────────────────────┘│
      │                                                             │
      └─────────────────────────────────────────────────────────────┘

  """

  use GenServer

  require Logger

  defstruct [:id, :os_pid, :parent, :shell, :rows, :cols, output_buffer: ""]

  @doc """
  Start a PTY handler process.

  ## Options

    * `:id` - Unique PTY identifier
    * `:shell` - Shell to spawn (default: "/bin/bash")
    * `:rows` - Terminal rows (default: 24)
    * `:cols` - Terminal columns (default: 80)
    * `:parent` - Parent process to receive output

  """
  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @doc """
  Send input to the PTY.
  """
  @spec send_input(pid(), binary()) :: :ok
  def send_input(pid, data) do
    GenServer.cast(pid, {:input, data})
  end

  @doc """
  Resize the PTY.
  """
  @spec resize(pid(), integer(), integer()) :: :ok
  def resize(pid, rows, cols) do
    GenServer.cast(pid, {:resize, rows, cols})
  end

  @doc """
  Get buffered output.
  """
  @spec get_output(pid()) :: {:ok, binary()}
  def get_output(pid) do
    GenServer.call(pid, :get_output)
  end

  @doc """
  Close the PTY.
  """
  @spec close(pid()) :: :ok
  def close(pid) do
    GenServer.cast(pid, :close)
  end

  # GenServer callbacks

  @impl true
  def init(config) do
    id = Map.fetch!(config, :id)
    shell = Map.get(config, :shell, "/bin/bash")
    rows = Map.get(config, :rows, 24)
    cols = Map.get(config, :cols, 80)
    parent = Map.fetch!(config, :parent)

    state = %__MODULE__{
      id: id,
      parent: parent,
      shell: shell,
      rows: rows,
      cols: cols
    }

    # Spawn the PTY process
    case spawn_pty(shell, rows, cols) do
      {:ok, os_pid} ->
        {:ok, %{state | os_pid: os_pid}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:input, data}, state) do
    if state.os_pid do
      :exec.send(state.os_pid, data)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:resize, rows, cols}, state) do
    if state.os_pid do
      # Send SIGWINCH to the process
      :exec.winsz(state.os_pid, rows, cols)
    end

    {:noreply, %{state | rows: rows, cols: cols}}
  end

  @impl true
  def handle_cast(:close, state) do
    if state.os_pid do
      :exec.stop(state.os_pid)
    end

    {:stop, :normal, state}
  end

  @impl true
  def handle_call(:get_output, _from, state) do
    output = state.output_buffer
    {:reply, {:ok, output}, %{state | output_buffer: ""}}
  end

  @impl true
  def handle_info({:stdout, os_pid, data}, %{os_pid: os_pid} = state) do
    # Forward output to parent
    send(state.parent, {:pty_output, state.id, data})

    # Buffer output
    new_buffer = state.output_buffer <> data
    {:noreply, %{state | output_buffer: new_buffer}}
  end

  @impl true
  def handle_info({:stderr, os_pid, data}, %{os_pid: os_pid} = state) do
    # Treat stderr same as stdout for terminal
    send(state.parent, {:pty_output, state.id, data})
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, os_pid, :process, _, reason}, %{os_pid: os_pid} = state) do
    exit_code =
      case reason do
        :normal -> 0
        {:exit_status, code} -> code
        _ -> 1
      end

    send(state.parent, {:pty_exit, state.id, exit_code})
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.os_pid do
      try do
        :exec.stop(state.os_pid)
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  # Private functions

  defp spawn_pty(shell, rows, cols) do
    # Build environment for the PTY
    env = [
      {"TERM", "xterm-256color"},
      {"LINES", to_string(rows)},
      {"COLUMNS", to_string(cols)}
    ]

    # Options for erlexec
    opts = [
      :stdin,
      :stdout,
      :stderr,
      :pty,
      :pty_echo,
      :monitor,
      {:env, env},
      {:cd, System.get_env("HOME", "/tmp")}
    ]

    try do
      case :exec.run(shell, opts) do
        {:ok, _pid, os_pid} ->
          {:ok, os_pid}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      e ->
        Logger.error("Failed to spawn PTY: #{inspect(e)}")
        {:error, {:spawn_failed, e}}
    end
  end
end
