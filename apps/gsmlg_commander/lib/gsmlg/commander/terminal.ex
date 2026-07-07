defmodule GSMLG.Commander.Terminal do
  @moduledoc """
  Phoenix channel handler for PTY terminal sessions on agent side.

  Manages WebSocket communication between the agent and control server,
  handling PTY creation, input/output streaming, and session lifecycle.
  """

  use GenServer
  require Logger
  alias GSMLG.Commander.{SessionManager, Protocol}
  alias Phoenix.SocketClient.Message

  @heartbeat_interval 60_000
  @reconnect_after 1_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    socket = Keyword.fetch!(opts, :socket)
    name = Keyword.fetch!(opts, :name)
    topic = "terminal:#{name}"

    GSMLG.Telemetry.info("Starting Terminal channel",
      metadata: %{
        topic: topic,
        name: name
      }
    )

    state = %{
      topic: topic,
      name: name,
      socket: socket,
      channel: nil,
      sessions: %{},
      heartbeat_timer: nil,
      join_fun: Keyword.get(opts, :join_fun, &Phoenix.SocketClient.Channel.join/2),
      push_fun: Keyword.get(opts, :push_fun, &Phoenix.SocketClient.Channel.push_async/3),
      heartbeat_interval: Keyword.get(opts, :heartbeat_interval, @heartbeat_interval),
      reconnect_after: Keyword.get(opts, :reconnect_after, @reconnect_after)
    }

    {:ok, join_terminal(state)}
  end

  @impl true
  def handle_info({:phoenix_channel_join, {:ok, response}}, state) do
    GSMLG.Telemetry.info("Terminal channel joined successfully",
      metadata: %{
        topic: state.topic,
        response: inspect(response)
      }
    )

    # Send registration message with current sessions
    send_register_message(state)

    {:noreply, schedule_heartbeat(state)}
  end

  @impl true
  def handle_info({:phoenix_channel_join, {:error, reason}}, state) do
    GSMLG.Telemetry.error("Failed to join Terminal channel",
      metadata: %{
        topic: state.topic,
        reason: inspect(reason)
      }
    )

    schedule_reconnect(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:phoenix_channel_message, "message", payload}, state) do
    handle_channel_payload(payload, state)
  end

  @impl true
  def handle_info(%Message{event: "message", payload: payload}, state) do
    handle_channel_payload(payload, state)
  end

  @impl true
  def handle_info(%{"type" => _type} = payload, state) do
    handle_channel_payload(payload, state)
  end

  @impl true
  def handle_info({:phoenix_channel_leave, reason}, state) do
    GSMLG.Telemetry.warn("Terminal channel left",
      metadata: %{
        topic: state.topic,
        reason: inspect(reason)
      }
    )

    if state.heartbeat_timer do
      Process.cancel_timer(state.heartbeat_timer)
    end

    schedule_reconnect(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:pty_created, data}, state) do
    send_message(
      %{
        type: "pty_created",
        session_id: data.session_id,
        command: data.command,
        dimensions: data.dimensions,
        os_pid: data.os_pid
      },
      state
    )

    new_sessions = Map.put(state.sessions, data.session_id, %{state: :running})
    {:noreply, %{state | sessions: new_sessions}}
  end

  def handle_info({:pty_output, data}, state) do
    send_message(
      %{
        type: "pty_output",
        session_id: data.session_id,
        data: data.data
      },
      state
    )

    {:noreply, state}
  end

  def handle_info({:pty_closed, data}, state) do
    send_message(
      %{
        type: "pty_closed",
        session_id: data.session_id,
        exit_code: data.exit_code,
        reason: inspect(data.reason)
      },
      state
    )

    new_sessions = Map.delete(state.sessions, data.session_id)
    {:noreply, %{state | sessions: new_sessions}}
  end

  def handle_info({:pty_resized, data}, state) do
    send_message(
      %{
        type: "pty_resized",
        session_id: data.session_id,
        rows: data.rows,
        cols: data.cols
      },
      state
    )

    {:noreply, state}
  end

  def handle_info({:pty_error, data}, state) do
    send_message(
      %{
        type: "error",
        session_id: data.session_id,
        error_code: "pty_spawn_failed",
        message: inspect(data.reason)
      },
      state
    )

    {:noreply, state}
  end

  def handle_info(:heartbeat, state) do
    active_sessions = SessionManager.session_count()

    send_message(
      %{
        type: "heartbeat",
        active_sessions: active_sessions,
        timestamp: System.system_time(:millisecond)
      },
      state
    )

    timer = Process.send_after(self(), :heartbeat, @heartbeat_interval)
    {:noreply, %{state | heartbeat_timer: timer}}
  end

  @impl true
  def handle_info(:reconnect, state) do
    GSMLG.Telemetry.info("Attempting to reconnect Terminal channel",
      metadata: %{
        topic: state.topic
      }
    )

    # Rejoin the channel
    {:noreply, join_terminal(state)}
  end

  @impl true
  def handle_info(msg, state) do
    GSMLG.Telemetry.debug("Unhandled message in Terminal channel",
      metadata: %{
        message: inspect(msg)
      }
    )

    {:noreply, state}
  end

  # Protocol Message Handlers

  defp handle_protocol_message(:create_pty, data, state) do
    GSMLG.Telemetry.info("Creating PTY session",
      metadata: %{
        session_id: data.session_id,
        command: data.command
      }
    )

    session_opts = [
      session_id: data.session_id,
      command: data.command,
      dimensions: normalize_dimensions(data.dimensions),
      env_vars: data.env_vars || %{},
      working_dir: data.working_dir,
      terminal_pid: self()
    ]

    case SessionManager.create_session(session_opts) do
      {:ok, session_id} ->
        GSMLG.Telemetry.info("PTY session created successfully",
          metadata: %{
            session_id: session_id
          }
        )

        {:noreply, state}

      {:error, reason} ->
        GSMLG.Telemetry.error("Failed to create PTY session",
          metadata: %{
            session_id: data.session_id,
            reason: inspect(reason)
          }
        )

        send_message(
          %{
            type: "error",
            session_id: data.session_id,
            error_code: "create_failed",
            message: inspect(reason)
          },
          state
        )

        {:noreply, state}
    end
  end

  defp handle_protocol_message(:close_pty, data, state) do
    GSMLG.Telemetry.info("Closing PTY session",
      metadata: %{
        session_id: data.session_id,
        force: data.force
      }
    )

    case SessionManager.terminate_session(data.session_id, data.force) do
      :ok ->
        {:noreply, state}

      {:error, reason} ->
        GSMLG.Telemetry.warn("Failed to close PTY session",
          metadata: %{
            session_id: data.session_id,
            reason: inspect(reason)
          }
        )

        {:noreply, state}
    end
  end

  defp handle_protocol_message(:attach_pty, data, state) do
    case SessionManager.attach_session(data.session_id, self()) do
      :ok ->
        GSMLG.Telemetry.debug("Attached to PTY session",
          metadata: %{
            session_id: data.session_id
          }
        )

        {:noreply, state}

      {:error, reason} ->
        GSMLG.Telemetry.warn("Failed to attach to PTY session",
          metadata: %{
            session_id: data.session_id,
            reason: inspect(reason)
          }
        )

        {:noreply, state}
    end
  end

  defp handle_protocol_message(:detach_pty, data, state) do
    case SessionManager.detach_session(data.session_id) do
      :ok ->
        GSMLG.Telemetry.debug("Detached from PTY session",
          metadata: %{
            session_id: data.session_id
          }
        )

        {:noreply, state}

      {:error, reason} ->
        GSMLG.Telemetry.warn("Failed to detach from PTY session",
          metadata: %{
            session_id: data.session_id,
            reason: inspect(reason)
          }
        )

        {:noreply, state}
    end
  end

  defp handle_protocol_message(:send_input, data, state) do
    case SessionManager.send_input(data.session_id, data.data) do
      :ok ->
        {:noreply, state}

      {:error, reason} ->
        GSMLG.Telemetry.warn("Failed to send input to PTY",
          metadata: %{
            session_id: data.session_id,
            reason: inspect(reason)
          }
        )

        {:noreply, state}
    end
  end

  defp handle_protocol_message(:resize_pty, data, state) do
    case SessionManager.resize_session(data.session_id, data.rows, data.cols) do
      :ok ->
        GSMLG.Telemetry.debug("Resized PTY session",
          metadata: %{
            session_id: data.session_id,
            rows: data.rows,
            cols: data.cols
          }
        )

        {:noreply, state}

      {:error, reason} ->
        GSMLG.Telemetry.warn("Failed to resize PTY session",
          metadata: %{
            session_id: data.session_id,
            reason: inspect(reason)
          }
        )

        {:noreply, state}
    end
  end

  defp handle_protocol_message(:list_sessions, _data, state) do
    sessions = SessionManager.list_sessions()

    send_message(
      %{
        type: "sessions_list",
        sessions: sessions
      },
      state
    )

    {:noreply, state}
  end

  defp handle_protocol_message(:configure, data, state) do
    GSMLG.Telemetry.info("Received configuration update",
      metadata: %{
        settings: inspect(data.settings)
      }
    )

    # TODO: Apply configuration settings
    {:noreply, state}
  end

  # Helper Functions

  defp join_terminal(state) do
    case state.join_fun.(state.socket, state.topic) do
      {:ok, response, channel} ->
        handle_joined(response, channel, state)

      {:error, {:already_joined, channel}} ->
        GSMLG.Telemetry.info("Terminal channel already joined",
          metadata: %{
            topic: state.topic
          }
        )

        %{state | channel: channel}

      {:error, reason} ->
        schedule_join_retry(reason, state)
    end
  end

  defp schedule_join_retry(reason, state)
       when reason in [:socket_not_connected, :socket_not_started] do
    GSMLG.Telemetry.debug("Terminal waiting for socket before joining channel",
      metadata: %{
        topic: state.topic,
        reason: inspect(reason),
        retry_delay: state.reconnect_after
      }
    )

    schedule_reconnect(state)
    state
  end

  defp schedule_join_retry(reason, state) do
    GSMLG.Telemetry.error("Failed to join Terminal channel",
      metadata: %{
        topic: state.topic,
        reason: inspect(reason),
        will_retry: true,
        retry_delay: state.reconnect_after
      }
    )

    schedule_reconnect(state)
    state
  end

  defp handle_joined(response, channel, state) do
    GSMLG.Telemetry.info("Terminal channel joined successfully",
      metadata: %{
        topic: state.topic,
        response: inspect(response)
      }
    )

    state = %{state | channel: channel}

    send_register_message(state)
    schedule_heartbeat(state)
  end

  defp handle_channel_payload(payload, state) do
    GSMLG.Telemetry.debug("Received message on Terminal channel",
      metadata: %{
        payload: inspect(payload)
      }
    )

    case Protocol.parse_message(payload) do
      {:ok, message_type, data} ->
        handle_protocol_message(message_type, data, state)

      {:error, reason} ->
        GSMLG.Telemetry.warn("Failed to parse message",
          metadata: %{
            reason: inspect(reason),
            payload: inspect(payload)
          }
        )

        {:noreply, state}
    end
  end

  defp send_register_message(state) do
    hostname = :inet.gethostname() |> elem(1) |> to_string()
    sessions = SessionManager.list_sessions()

    message = %{
      type: "register",
      agent_id: state.name,
      hostname: hostname,
      capabilities: ["pty", "shell", "resize"],
      version: "1.0.0",
      active_sessions: length(sessions),
      sessions: Enum.map(sessions, & &1.session_id),
      timestamp: System.system_time(:millisecond)
    }

    send_message(message, state)
  end

  defp send_message(message, state) do
    if state.channel do
      state.push_fun.(state.channel, "message", message)
    else
      GSMLG.Telemetry.warn("Terminal channel is not joined; dropping message",
        metadata: %{
          topic: state.topic,
          message_type: message[:type] || message["type"]
        }
      )

      {:error, :not_joined}
    end
  end

  defp schedule_reconnect(state) do
    Process.send_after(self(), :reconnect, state.reconnect_after)
  end

  defp schedule_heartbeat(state) do
    if state.heartbeat_timer do
      Process.cancel_timer(state.heartbeat_timer)
    end

    timer = Process.send_after(self(), :heartbeat, state.heartbeat_interval)
    %{state | heartbeat_timer: timer}
  end

  defp normalize_dimensions(%{"rows" => rows, "cols" => cols}) do
    %{rows: rows, cols: cols}
  end

  defp normalize_dimensions(%{rows: rows, cols: cols}) do
    %{rows: rows, cols: cols}
  end

  defp normalize_dimensions(_) do
    %{rows: 24, cols: 80}
  end
end
