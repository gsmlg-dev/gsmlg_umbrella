defmodule GSMLG.Commander.Protocol do
  @moduledoc """
  Protocol for PTY agent communication with remote server.

  Defines message types and provides encoding/decoding functionality
  for bidirectional communication between PTY agents and control server.
  """

  @type message_type ::
          :register
          | :pty_output
          | :pty_created
          | :pty_closed
          | :pty_resized
          | :error
          | :heartbeat
          | :create_pty
          | :close_pty
          | :attach_pty
          | :detach_pty
          | :send_input
          | :resize_pty
          | :list_sessions
          | :configure

  @type message :: %{
          required(:type) => String.t(),
          optional(:session_id) => String.t(),
          optional(atom()) => any()
        }

  # Agent → Server Messages

  @doc """
  Creates a REGISTER message sent when agent connects to server.
  """
  def register_message(agent_id, hostname, capabilities, version) do
    %{
      type: "register",
      agent_id: agent_id,
      hostname: hostname,
      capabilities: capabilities,
      version: version,
      timestamp: System.system_time(:millisecond)
    }
  end

  @doc """
  Creates a PTY_OUTPUT message containing terminal output data.
  """
  def pty_output_message(session_id, data) do
    %{
      type: "pty_output",
      session_id: session_id,
      data: data,
      timestamp: System.system_time(:millisecond)
    }
  end

  @doc """
  Creates a PTY_CREATED message after successfully spawning a PTY.
  """
  def pty_created_message(session_id, command, dimensions, os_pid) do
    %{
      type: "pty_created",
      session_id: session_id,
      command: command,
      dimensions: dimensions,
      os_pid: os_pid,
      timestamp: System.system_time(:millisecond)
    }
  end

  @doc """
  Creates a PTY_CLOSED message when a PTY session terminates.
  """
  def pty_closed_message(session_id, exit_code, reason) do
    %{
      type: "pty_closed",
      session_id: session_id,
      exit_code: exit_code,
      reason: reason,
      timestamp: System.system_time(:millisecond)
    }
  end

  @doc """
  Creates a PTY_RESIZED message after terminal resize.
  """
  def pty_resized_message(session_id, rows, cols) do
    %{
      type: "pty_resized",
      session_id: session_id,
      rows: rows,
      cols: cols,
      timestamp: System.system_time(:millisecond)
    }
  end

  @doc """
  Creates an ERROR message for reporting failures.
  """
  def error_message(error_code, message, session_id \\ nil) do
    %{
      type: "error",
      error_code: error_code,
      message: message,
      session_id: session_id,
      timestamp: System.system_time(:millisecond)
    }
  end

  @doc """
  Creates a HEARTBEAT message with agent status.
  """
  def heartbeat_message(active_sessions) do
    %{
      type: "heartbeat",
      active_sessions: active_sessions,
      timestamp: System.system_time(:millisecond)
    }
  end

  # Server → Agent Messages (Parsing)

  @doc """
  Parses incoming messages from server and validates structure.
  """
  def parse_message(message) when is_map(message) do
    case message do
      %{"type" => "create_pty"} = msg ->
        parse_create_pty(msg)

      %{"type" => "close_pty"} = msg ->
        parse_close_pty(msg)

      %{"type" => "attach_pty"} = msg ->
        parse_attach_pty(msg)

      %{"type" => "detach_pty"} = msg ->
        parse_detach_pty(msg)

      %{"type" => "send_input"} = msg ->
        parse_send_input(msg)

      %{"type" => "resize_pty"} = msg ->
        parse_resize_pty(msg)

      %{"type" => "list_sessions"} ->
        {:ok, :list_sessions, %{}}

      %{"type" => "configure"} = msg ->
        parse_configure(msg)

      _ ->
        {:error, :unknown_message_type}
    end
  end

  def parse_message(_), do: {:error, :invalid_message_format}

  # Private parsing functions

  defp parse_create_pty(
         %{
           "session_id" => session_id,
           "command" => command
         } = msg
       ) do
    dimensions = msg["dimensions"] || %{"rows" => 24, "cols" => 80}
    env_vars = msg["env_vars"] || %{}
    working_dir = msg["working_dir"]

    {:ok, :create_pty,
     %{
       session_id: session_id,
       command: command,
       dimensions: dimensions,
       env_vars: env_vars,
       working_dir: working_dir
     }}
  end

  defp parse_create_pty(_), do: {:error, :invalid_create_pty_message}

  defp parse_close_pty(%{"session_id" => session_id} = msg) do
    force = msg["force"] || false
    {:ok, :close_pty, %{session_id: session_id, force: force}}
  end

  defp parse_close_pty(_), do: {:error, :invalid_close_pty_message}

  defp parse_attach_pty(%{"session_id" => session_id}) do
    {:ok, :attach_pty, %{session_id: session_id}}
  end

  defp parse_attach_pty(_), do: {:error, :invalid_attach_pty_message}

  defp parse_detach_pty(%{"session_id" => session_id}) do
    {:ok, :detach_pty, %{session_id: session_id}}
  end

  defp parse_detach_pty(_), do: {:error, :invalid_detach_pty_message}

  defp parse_send_input(%{"session_id" => session_id, "data" => data}) do
    {:ok, :send_input, %{session_id: session_id, data: data}}
  end

  defp parse_send_input(_), do: {:error, :invalid_send_input_message}

  defp parse_resize_pty(%{
         "session_id" => session_id,
         "rows" => rows,
         "cols" => cols
       }) do
    {:ok, :resize_pty, %{session_id: session_id, rows: rows, cols: cols}}
  end

  defp parse_resize_pty(_), do: {:error, :invalid_resize_pty_message}

  defp parse_configure(%{"settings" => settings}) do
    {:ok, :configure, %{settings: settings}}
  end

  defp parse_configure(_), do: {:error, :invalid_configure_message}

  @doc """
  Encodes a message to JSON for transmission.
  """
  def encode(message) when is_map(message) do
    Jason.encode(message)
  end

  @doc """
  Decodes a JSON message from the wire.
  """
  def decode(json_string) when is_binary(json_string) do
    case Jason.decode(json_string) do
      {:ok, decoded} -> parse_message(decoded)
      {:error, reason} -> {:error, {:json_decode_error, reason}}
    end
  end

  @doc """
  Validates message structure and required fields.
  """
  def validate_message(message) when is_map(message) do
    if Map.has_key?(message, :type) do
      {:ok, message}
    else
      {:error, :missing_type_field}
    end
  end

  def validate_message(_), do: {:error, :invalid_message_structure}

  @doc """
  Generates a unique session ID for a new PTY session.
  """
  def generate_session_id(agent_name) do
    timestamp = System.system_time(:millisecond)
    random_hex = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    "#{agent_name}_#{timestamp}_#{random_hex}"
  end
end
