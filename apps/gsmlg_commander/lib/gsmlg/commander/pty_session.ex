defmodule GSMLG.Commander.PTYSession do
  @moduledoc """
  GenServer that manages an individual PTY (pseudo-terminal) session.

  Wraps erlexec to spawn and control a PTY process, handles bidirectional
  I/O streaming, output buffering, terminal resizing, and proper cleanup.
  """

  use GenServer
  require Logger

  @buffer_flush_interval 30
  @buffer_max_size 65_536
  @idle_timeout :timer.minutes(30)

  defstruct [
    :session_id,
    :os_pid,
    :exec_pid,
    :command,
    :working_dir,
    :env_vars,
    :dimensions,
    :created_at,
    :last_activity,
    :state,
    :terminal_pid,
    :output_buffer,
    :buffer_timer,
    :memory_limit
  ]

  @type t :: %__MODULE__{
          session_id: String.t(),
          os_pid: non_neg_integer() | nil,
          exec_pid: pid() | nil,
          command: String.t(),
          working_dir: String.t() | nil,
          env_vars: map(),
          dimensions: %{rows: integer(), cols: integer()},
          created_at: integer(),
          last_activity: integer(),
          state: :initializing | :running | :attached | :detached | :closing | :closed,
          terminal_pid: pid() | nil,
          output_buffer: binary(),
          buffer_timer: reference() | nil,
          memory_limit: non_neg_integer()
        }

  # Client API

  @doc """
  Starts a new PTY session.
  """
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(session_id))
  end

  @doc """
  Sends input data to the PTY.
  """
  def send_input(session_id, data) do
    GenServer.cast(via_tuple(session_id), {:send_input, data})
  end

  @doc """
  Resizes the PTY terminal.
  """
  def resize(session_id, rows, cols) do
    GenServer.cast(via_tuple(session_id), {:resize, rows, cols})
  end

  @doc """
  Attaches a controlling process (terminal channel) to the session.
  """
  def attach(session_id, terminal_pid) do
    GenServer.call(via_tuple(session_id), {:attach, terminal_pid})
  end

  @doc """
  Detaches the controlling process from the session.
  """
  def detach(session_id) do
    GenServer.call(via_tuple(session_id), :detach)
  end

  @doc """
  Closes the PTY session.
  """
  def close(session_id, force \\ false) do
    GenServer.call(via_tuple(session_id), {:close, force})
  end

  @doc """
  Gets session metadata.
  """
  def get_info(session_id) do
    GenServer.call(via_tuple(session_id), :get_info)
  end

  defp via_tuple(session_id) do
    {:via, Registry, {GSMLG.Commander.LocalSessionRegistry, session_id}}
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      session_id: Keyword.fetch!(opts, :session_id),
      command: Keyword.fetch!(opts, :command),
      working_dir: Keyword.get(opts, :working_dir),
      env_vars: Keyword.get(opts, :env_vars, %{}),
      dimensions: Keyword.get(opts, :dimensions, %{rows: 24, cols: 80}),
      terminal_pid: Keyword.fetch!(opts, :terminal_pid),
      created_at: System.system_time(:millisecond),
      last_activity: System.system_time(:millisecond),
      state: :initializing,
      output_buffer: "",
      buffer_timer: nil,
      memory_limit: Keyword.get(opts, :memory_limit, 50_000_000)
    }

    GSMLG.Telemetry.info("Starting PTY session",
      metadata: %{
        session_id: state.session_id,
        command: state.command
      }
    )

    {:ok, state, {:continue, :spawn_pty}}
  end

  @impl true
  def handle_continue(:spawn_pty, state) do
    case spawn_pty(state) do
      {:ok, exec_pid, os_pid} ->
        new_state = %{state | exec_pid: exec_pid, os_pid: os_pid, state: :running}

        notify_terminal(new_state.terminal_pid, :pty_created, %{
          session_id: new_state.session_id,
          os_pid: os_pid,
          command: new_state.command,
          dimensions: new_state.dimensions
        })

        GSMLG.Telemetry.info("PTY session spawned successfully",
          metadata: %{
            session_id: state.session_id,
            os_pid: os_pid
          }
        )

        schedule_idle_check()
        {:noreply, new_state}

      {:error, reason} ->
        GSMLG.Telemetry.error("Failed to spawn PTY",
          metadata: %{
            session_id: state.session_id,
            reason: inspect(reason)
          }
        )

        notify_terminal(state.terminal_pid, :pty_error, %{
          session_id: state.session_id,
          reason: reason
        })

        {:stop, {:spawn_failed, reason}, state}
    end
  end

  @impl true
  def handle_cast({:send_input, data}, state) do
    case :exec.send(state.os_pid, data) do
      :ok ->
        {:noreply, update_activity(state)}

      {:error, reason} ->
        GSMLG.Telemetry.warn("Failed to send input to PTY",
          metadata: %{
            session_id: state.session_id,
            reason: inspect(reason)
          }
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:resize, rows, cols}, state) do
    case :exec.winsz(state.exec_pid, rows, cols) do
      :ok ->
        new_state = %{state | dimensions: %{rows: rows, cols: cols}}

        notify_terminal(state.terminal_pid, :pty_resized, %{
          session_id: state.session_id,
          rows: rows,
          cols: cols
        })

        GSMLG.Telemetry.debug("PTY resized",
          metadata: %{
            session_id: state.session_id,
            rows: rows,
            cols: cols
          }
        )

        {:noreply, new_state}

      {:error, reason} ->
        GSMLG.Telemetry.warn("Failed to resize PTY",
          metadata: %{
            session_id: state.session_id,
            reason: inspect(reason)
          }
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:attach, terminal_pid}, _from, state) do
    Process.monitor(terminal_pid)

    new_state = %{state | terminal_pid: terminal_pid, state: :attached}

    GSMLG.Telemetry.debug("Terminal attached to session",
      metadata: %{
        session_id: state.session_id,
        terminal_pid: inspect(terminal_pid)
      }
    )

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:detach, _from, state) do
    new_state = %{state | state: :detached}

    GSMLG.Telemetry.debug("Terminal detached from session",
      metadata: %{
        session_id: state.session_id
      }
    )

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:close, force}, _from, state) do
    GSMLG.Telemetry.info("Closing PTY session",
      metadata: %{
        session_id: state.session_id,
        force: force
      }
    )

    if force do
      :exec.kill(state.os_pid, 9)
    else
      :exec.stop(state.os_pid)
    end

    {:reply, :ok, %{state | state: :closing}}
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    info = %{
      session_id: state.session_id,
      os_pid: state.os_pid,
      command: state.command,
      dimensions: state.dimensions,
      created_at: state.created_at,
      last_activity: state.last_activity,
      state: state.state,
      uptime: System.system_time(:millisecond) - state.created_at
    }

    {:reply, info, state}
  end

  @impl true
  def handle_info({:stdout, os_pid, data}, %{os_pid: os_pid} = state) do
    new_state =
      state
      |> append_to_buffer(data)
      |> schedule_buffer_flush()
      |> update_activity()
      |> check_memory_limit()

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:stderr, os_pid, data}, %{os_pid: os_pid} = state) do
    new_state =
      state
      |> append_to_buffer(data)
      |> schedule_buffer_flush()
      |> update_activity()
      |> check_memory_limit()

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:DOWN, os_pid, :process, _pid, status}, %{os_pid: os_pid} = state) do
    exit_code = extract_exit_code(status)

    GSMLG.Telemetry.info("PTY process terminated",
      metadata: %{
        session_id: state.session_id,
        exit_code: exit_code,
        status: inspect(status)
      }
    )

    flush_buffer(state)

    notify_terminal(state.terminal_pid, :pty_closed, %{
      session_id: state.session_id,
      exit_code: exit_code,
      reason: status
    })

    {:stop, :normal, %{state | state: :closed}}
  end

  @impl true
  def handle_info(:flush_buffer, state) do
    {:noreply, flush_buffer(state)}
  end

  @impl true
  def handle_info(:check_idle, state) do
    idle_time = System.system_time(:millisecond) - state.last_activity

    if idle_time > @idle_timeout do
      GSMLG.Telemetry.info("PTY session idle timeout",
        metadata: %{
          session_id: state.session_id,
          idle_time: idle_time
        }
      )

      :exec.stop(state.os_pid)
      {:noreply, %{state | state: :closing}}
    else
      schedule_idle_check()
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{terminal_pid: pid} = state) do
    GSMLG.Telemetry.info("Terminal process died, detaching",
      metadata: %{
        session_id: state.session_id
      }
    )

    {:noreply, %{state | state: :detached}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    GSMLG.Telemetry.info("PTY session terminating",
      metadata: %{
        session_id: state.session_id,
        reason: inspect(reason)
      }
    )

    if state.os_pid do
      :exec.stop(state.os_pid)
    end

    :ok
  end

  # Private Functions

  defp spawn_pty(state) do
    exec_opts = [
      :stdin,
      :stdout,
      :stderr,
      :pty,
      :pty_echo,
      :monitor,
      {:env, env_list(state.env_vars)},
      {:winsz, {state.dimensions.rows, state.dimensions.cols}}
    ]

    exec_opts =
      if state.working_dir do
        [{:cd, state.working_dir} | exec_opts]
      else
        exec_opts
      end

    case :exec.run(state.command, exec_opts) do
      {:ok, exec_pid, os_pid} ->
        {:ok, exec_pid, os_pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp env_list(env_vars) when is_map(env_vars) do
    Enum.map(env_vars, fn {k, v} -> "#{k}=#{v}" end)
  end

  defp append_to_buffer(state, data) do
    %{state | output_buffer: state.output_buffer <> data}
  end

  defp schedule_buffer_flush(state) do
    if state.buffer_timer do
      state
    else
      timer = Process.send_after(self(), :flush_buffer, @buffer_flush_interval)
      %{state | buffer_timer: timer}
    end
  end

  defp flush_buffer(%{output_buffer: ""} = state) do
    %{state | buffer_timer: nil}
  end

  defp flush_buffer(state) do
    if state.terminal_pid do
      notify_terminal(state.terminal_pid, :pty_output, %{
        session_id: state.session_id,
        data: state.output_buffer
      })
    end

    %{state | output_buffer: "", buffer_timer: nil}
  end

  defp check_memory_limit(state) do
    if byte_size(state.output_buffer) > @buffer_max_size do
      GSMLG.Telemetry.warn("Buffer size exceeded, flushing",
        metadata: %{
          session_id: state.session_id,
          buffer_size: byte_size(state.output_buffer)
        }
      )

      flush_buffer(state)
    else
      state
    end
  end

  defp update_activity(state) do
    %{state | last_activity: System.system_time(:millisecond)}
  end

  defp schedule_idle_check do
    Process.send_after(self(), :check_idle, :timer.minutes(5))
  end

  defp extract_exit_code({:exit_status, code}), do: code
  defp extract_exit_code(_), do: nil

  defp notify_terminal(nil, _event, _data), do: :ok

  defp notify_terminal(terminal_pid, event, data) do
    send(terminal_pid, {event, data})
  end
end
