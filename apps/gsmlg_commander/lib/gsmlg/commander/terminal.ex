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

  @reconnect_after 1_000
  @server_message_codes %{
    "create_pty" => :create_pty,
    "close_pty" => :close_pty,
    "attach_pty" => :attach_pty,
    "detach_pty" => :detach_pty,
    "send_input" => :send_input,
    "resize_pty" => :resize_pty,
    "list_sessions" => :list_sessions,
    "configure" => :configure,
    "pty_spawn" => :pty_spawn,
    "pty_kill" => :pty_kill,
    "auth_request" => :auth_request,
    "heartbeat" => :heartbeat
  }
  @parse_error_codes [
    :unknown_message_type,
    :invalid_message_format,
    :invalid_create_pty_message,
    :invalid_pty_spawn_message,
    :invalid_close_pty_message,
    :invalid_pty_kill_message,
    :invalid_attach_pty_message,
    :invalid_detach_pty_message,
    :invalid_send_input_message,
    :invalid_resize_pty_message,
    :invalid_configure_message,
    :invalid_auth_request_message
  ]
  @transport_error_codes [:socket_not_connected, :socket_not_started, :timeout, :closed]
  @operation_error_codes [
    :session_not_found,
    :session_limit_reached,
    :command_required,
    :empty_command,
    :command_too_long,
    :invalid_command
  ]
  @agent_message_codes %{
    "pty_created" => :pty_created,
    "pty_output" => :pty_output,
    "pty_closed" => :pty_closed,
    "pty_resized" => :pty_resized,
    "error" => :error,
    "sessions_list" => :sessions_list
  }

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
      channel_ref: nil,
      sessions: %{},
      join_fun: Keyword.get(opts, :join_fun, &Phoenix.SocketClient.Channel.join/2),
      push_fun: Keyword.get(opts, :push_fun, &Phoenix.SocketClient.Channel.push_async/3),
      reconnect_after: Keyword.get(opts, :reconnect_after, @reconnect_after)
    }

    {:ok, join_terminal(state)}
  end

  @impl true
  def handle_info({:phoenix_channel_join, {:ok, response}}, state) do
    GSMLG.Telemetry.info("Terminal channel joined successfully",
      metadata: %{
        topic: state.topic,
        response_code: :joined,
        response_size: term_size(response)
      }
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({:phoenix_channel_join, {:error, reason}}, state) do
    GSMLG.Telemetry.error("Failed to join Terminal channel",
      metadata: %{
        topic: state.topic,
        error_code: transport_error_code(reason),
        reason_size: term_size(reason)
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
        reason_code: transport_reason_code(reason),
        reason_size: term_size(reason)
      }
    )

    schedule_reconnect(state)
    {:noreply, clear_channel(state)}
  end

  def handle_info(
        {:DOWN, ref, :process, channel, reason},
        %{channel_ref: ref, channel: channel} = state
      ) do
    GSMLG.Telemetry.info("Terminal channel process stopped",
      metadata: %{
        topic: state.topic,
        reason_code: transport_reason_code(reason),
        reason_size: term_size(reason)
      }
    )

    schedule_reconnect(state)
    {:noreply, %{state | channel: nil, channel_ref: nil}}
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
        message_code: :unknown,
        message_size: term_size(msg)
      }
    )

    {:noreply, state}
  end

  # Protocol Message Handlers

  defp handle_protocol_message(:create_pty, data, state) do
    GSMLG.Telemetry.info("Creating PTY session",
      metadata:
        Map.merge(session_metadata(data.session_id), %{
          command_size: binary_size(data.command)
        })
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
          metadata: session_metadata(session_id)
        )

        {:noreply, state}

      {:error, reason} ->
        GSMLG.Telemetry.error("Failed to create PTY session",
          metadata:
            Map.put(session_metadata(data.session_id), :error_code, operation_error_code(reason))
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
      metadata: session_metadata(data.session_id)
    )

    case SessionManager.terminate_session(data.session_id, data.force) do
      :ok ->
        {:noreply, state}

      {:error, reason} ->
        GSMLG.Telemetry.warn("Failed to close PTY session",
          metadata:
            Map.put(session_metadata(data.session_id), :error_code, operation_error_code(reason))
        )

        {:noreply, state}
    end
  end

  defp handle_protocol_message(:attach_pty, data, state) do
    case SessionManager.attach_session(data.session_id, self()) do
      :ok ->
        GSMLG.Telemetry.debug("Attached to PTY session",
          metadata: session_metadata(data.session_id)
        )

        {:noreply, state}

      {:error, reason} ->
        GSMLG.Telemetry.warn("Failed to attach to PTY session",
          metadata:
            Map.put(session_metadata(data.session_id), :error_code, operation_error_code(reason))
        )

        {:noreply, state}
    end
  end

  defp handle_protocol_message(:detach_pty, data, state) do
    case SessionManager.detach_session(data.session_id) do
      :ok ->
        GSMLG.Telemetry.debug("Detached from PTY session",
          metadata: session_metadata(data.session_id)
        )

        {:noreply, state}

      {:error, reason} ->
        GSMLG.Telemetry.warn("Failed to detach from PTY session",
          metadata:
            Map.put(session_metadata(data.session_id), :error_code, operation_error_code(reason))
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
          metadata:
            Map.put(session_metadata(data.session_id), :error_code, operation_error_code(reason))
        )

        {:noreply, state}
    end
  end

  defp handle_protocol_message(:resize_pty, data, state) do
    case SessionManager.resize_session(data.session_id, data.rows, data.cols) do
      :ok ->
        GSMLG.Telemetry.debug("Resized PTY session",
          metadata: session_metadata(data.session_id)
        )

        {:noreply, state}

      {:error, reason} ->
        GSMLG.Telemetry.warn("Failed to resize PTY session",
          metadata:
            Map.put(session_metadata(data.session_id), :error_code, operation_error_code(reason))
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
        setting_count: map_size(data.settings)
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

        put_channel(state, channel)

      {:error, reason} ->
        schedule_join_retry(reason, state)
    end
  end

  defp schedule_join_retry(reason, state)
       when reason in [:socket_not_connected, :socket_not_started] do
    GSMLG.Telemetry.debug("Terminal waiting for socket before joining channel",
      metadata: %{
        topic: state.topic,
        error_code: transport_error_code(reason),
        reason_size: term_size(reason),
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
        error_code: transport_error_code(reason),
        reason_size: term_size(reason),
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
        response_code: :joined,
        response_size: term_size(response)
      }
    )

    put_channel(state, channel)
  end

  defp handle_channel_payload(payload, state) do
    GSMLG.Telemetry.debug("Received message on Terminal channel",
      metadata: %{
        message_code: server_message_code(payload),
        payload_size: encoded_size(payload)
      }
    )

    case Protocol.parse_message(payload) do
      {:ok, message_type, data} ->
        handle_protocol_message(message_type, data, state)

      {:error, reason} ->
        GSMLG.Telemetry.warn("Failed to parse message",
          metadata: %{
            message_code: server_message_code(payload),
            error_code: parse_error_code(reason),
            payload_size: encoded_size(payload)
          }
        )

        {:noreply, state}
    end
  end

  defp send_message(message, state) do
    if state.channel do
      state.push_fun.(state.channel, "message", message)
    else
      GSMLG.Telemetry.warn("Terminal channel is not joined; dropping message",
        metadata: %{
          topic: state.topic,
          message_code: agent_message_code(message),
          payload_size: encoded_size(message)
        }
      )

      {:error, :not_joined}
    end
  end

  defp schedule_reconnect(state) do
    Process.send_after(self(), :reconnect, state.reconnect_after)
  end

  defp put_channel(state, channel) do
    state = clear_channel(state)

    # WORKAROUND(upstream): gsmlg-dev/phoenix_socket_client#106
    # Keep PTY compatibility alive until the dependency restores channel rejoin.
    ref = if is_pid(channel), do: Process.monitor(channel)
    %{state | channel: channel, channel_ref: ref}
  end

  defp clear_channel(%{channel_ref: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    %{state | channel: nil, channel_ref: nil}
  end

  defp clear_channel(state), do: %{state | channel: nil, channel_ref: nil}

  defp transport_error_code(reason) when reason in @transport_error_codes, do: reason
  defp transport_error_code(_reason), do: :transport_error

  defp transport_reason_code(reason) when reason in [:normal, :shutdown], do: reason
  defp transport_reason_code(reason), do: transport_error_code(reason)

  defp server_message_code(payload) when is_map(payload) do
    Map.get(@server_message_codes, payload["type"] || payload[:type], :unknown)
  end

  defp server_message_code(_payload), do: :unknown

  defp parse_error_code(reason) when reason in @parse_error_codes, do: reason
  defp parse_error_code(_reason), do: :invalid_payload

  defp operation_error_code(reason) when reason in @operation_error_codes, do: reason
  defp operation_error_code(_reason), do: :operation_failed

  defp agent_message_code(message) when is_map(message) do
    Map.get(@agent_message_codes, message[:type] || message["type"], :unknown)
  end

  defp agent_message_code(_message), do: :unknown

  defp encoded_size(payload) do
    payload |> JSON.encode!() |> byte_size()
  rescue
    _exception -> 0
  end

  defp term_size(term), do: :erlang.external_size(term)

  defp binary_size(value) when is_binary(value), do: byte_size(value)
  defp binary_size(_value), do: 0

  defp session_metadata(session_id) when is_binary(session_id) do
    %{
      session_id_hash: :crypto.hash(:sha256, session_id) |> Base.encode16(case: :lower),
      session_id_size: byte_size(session_id)
    }
  end

  defp session_metadata(_session_id), do: %{session_id_hash: nil, session_id_size: 0}

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
