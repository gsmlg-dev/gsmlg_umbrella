defmodule GSMLG.Commander.Protocol do
  @moduledoc """
  Protocol for PTY agent communication with remote server.

  Defines message types, frame structures, and provides encoding/decoding
  functionality for bidirectional communication between PTY agents and control server.

  ## Frame Structure

  ```
  ┌────────────────────────────────────────────────────────┐
  │                    Frame Structure                      │
  ├────────────────────────────────────────────────────────┤
  │  0       1       2       3       4       5+            │
  │ ┌───────┬───────┬───────────────┬───────────────────┐ │
  │ │ Type  │ Flags │   PTY ID      │     Payload       │ │
  │ │ (1B)  │ (1B)  │   (2B)        │    (variable)     │ │
  │ └───────┴───────┴───────────────┴───────────────────┘ │
  └────────────────────────────────────────────────────────┘
  ```

  ## Message Types

  | Type | Code | Direction | Description |
  |------|------|-----------|-------------|
  | AUTH_REQUEST | 0x01 | A->S | Initial authentication |
  | AUTH_RESPONSE | 0x02 | S->A | Auth success/failure |
  | HEARTBEAT | 0x03 | A<->S | Keep-alive ping/pong |
  | PTY_SPAWN | 0x10 | S->A | Request new PTY |
  | PTY_SPAWNED | 0x11 | A->S | PTY created with ID |
  | PTY_INPUT | 0x12 | S->A | Stdin to PTY |
  | PTY_OUTPUT | 0x13 | A->S | Stdout from PTY |
  | PTY_RESIZE | 0x14 | S->A | Terminal resize |
  | PTY_EXIT | 0x15 | A->S | PTY process ended |
  | PTY_KILL | 0x16 | S->A | Terminate PTY |
  | METADATA | 0x20 | A->S | Agent metadata update |
  | ERROR | 0xFF | A<->S | Error notification |
  """

  import Bitwise

  # Message Type Codes
  @auth_request 0x01
  @auth_response 0x02
  @heartbeat 0x03
  @pty_spawn 0x10
  @pty_spawned 0x11
  @pty_input 0x12
  @pty_output 0x13
  @pty_resize 0x14
  @pty_exit 0x15
  @pty_kill 0x16
  @metadata 0x20
  @error 0xFF

  # Flag bits
  @flag_compressed 0x01
  @flag_encrypted 0x02
  @flag_urgent 0x04
  @flag_ack_required 0x08

  @type message_type ::
          :auth_request
          | :auth_response
          | :heartbeat
          | :pty_spawn
          | :pty_spawned
          | :pty_input
          | :pty_output
          | :pty_resize
          | :pty_exit
          | :pty_kill
          | :metadata
          | :error
          # Legacy types for backward compatibility
          | :register
          | :pty_created
          | :pty_closed
          | :pty_resized
          | :create_pty
          | :close_pty
          | :attach_pty
          | :detach_pty
          | :send_input
          | :resize_pty
          | :list_sessions
          | :configure

  @type frame :: %{
          required(:type) => message_type(),
          required(:pty_id) => non_neg_integer(),
          optional(:flags) => non_neg_integer(),
          optional(:payload) => binary() | map()
        }

  @type message :: %{
          required(:type) => String.t(),
          optional(:session_id) => String.t(),
          optional(atom()) => any()
        }

  # ============================================================================
  # Binary Frame Encoding/Decoding
  # ============================================================================

  @doc """
  Encodes a frame into binary format.

  ## Examples

      iex> GSMLG.Commander.Protocol.encode_frame(:pty_output, 1, "hello")
      <<0x13, 0x00, 0x00, 0x01, "hello">>

  """
  @spec encode_frame(message_type(), non_neg_integer(), binary() | map()) :: binary()
  def encode_frame(type, pty_id, payload, flags \\ 0) do
    type_code = message_type_to_code(type)
    payload_bin = encode_payload(payload)
    <<type_code::8, flags::8, pty_id::16-big, payload_bin::binary>>
  end

  @doc """
  Decodes a binary frame into structured data.

  ## Examples

      iex> GSMLG.Commander.Protocol.decode_frame(<<0x13, 0x00, 0x00, 0x01, "hello">>)
      {:ok, %{type: :pty_output, pty_id: 1, flags: 0, payload: "hello"}}

  """
  @spec decode_frame(binary()) :: {:ok, frame()} | {:error, term()}
  def decode_frame(<<type_code::8, flags::8, pty_id::16-big, payload::binary>>) do
    case code_to_message_type(type_code) do
      {:ok, type} ->
        decoded_payload = decode_payload(type, payload)
        {:ok, %{type: type, pty_id: pty_id, flags: flags, payload: decoded_payload}}

      {:error, _} = error ->
        error
    end
  end

  def decode_frame(_), do: {:error, :invalid_frame}

  @doc """
  Checks if a flag is set in the flags byte.
  """
  @spec has_flag?(non_neg_integer(), atom()) :: boolean()
  def has_flag?(flags, :compressed), do: (flags &&& @flag_compressed) != 0
  def has_flag?(flags, :encrypted), do: (flags &&& @flag_encrypted) != 0
  def has_flag?(flags, :urgent), do: (flags &&& @flag_urgent) != 0
  def has_flag?(flags, :ack_required), do: (flags &&& @flag_ack_required) != 0

  @doc """
  Sets flags for a frame.
  """
  @spec set_flags([atom()]) :: non_neg_integer()
  def set_flags(flag_list) do
    Enum.reduce(flag_list, 0, fn
      :compressed, acc -> acc ||| @flag_compressed
      :encrypted, acc -> acc ||| @flag_encrypted
      :urgent, acc -> acc ||| @flag_urgent
      :ack_required, acc -> acc ||| @flag_ack_required
      _, acc -> acc
    end)
  end

  # ============================================================================
  # Message Type Conversion
  # ============================================================================

  defp message_type_to_code(:auth_request), do: @auth_request
  defp message_type_to_code(:auth_response), do: @auth_response
  defp message_type_to_code(:heartbeat), do: @heartbeat
  defp message_type_to_code(:pty_spawn), do: @pty_spawn
  defp message_type_to_code(:pty_spawned), do: @pty_spawned
  defp message_type_to_code(:pty_input), do: @pty_input
  defp message_type_to_code(:pty_output), do: @pty_output
  defp message_type_to_code(:pty_resize), do: @pty_resize
  defp message_type_to_code(:pty_exit), do: @pty_exit
  defp message_type_to_code(:pty_kill), do: @pty_kill
  defp message_type_to_code(:metadata), do: @metadata
  defp message_type_to_code(:error), do: @error
  defp message_type_to_code(_), do: @error

  defp code_to_message_type(@auth_request), do: {:ok, :auth_request}
  defp code_to_message_type(@auth_response), do: {:ok, :auth_response}
  defp code_to_message_type(@heartbeat), do: {:ok, :heartbeat}
  defp code_to_message_type(@pty_spawn), do: {:ok, :pty_spawn}
  defp code_to_message_type(@pty_spawned), do: {:ok, :pty_spawned}
  defp code_to_message_type(@pty_input), do: {:ok, :pty_input}
  defp code_to_message_type(@pty_output), do: {:ok, :pty_output}
  defp code_to_message_type(@pty_resize), do: {:ok, :pty_resize}
  defp code_to_message_type(@pty_exit), do: {:ok, :pty_exit}
  defp code_to_message_type(@pty_kill), do: {:ok, :pty_kill}
  defp code_to_message_type(@metadata), do: {:ok, :metadata}
  defp code_to_message_type(@error), do: {:ok, :error}
  defp code_to_message_type(code), do: {:error, {:unknown_type_code, code}}

  # ============================================================================
  # Payload Encoding/Decoding
  # ============================================================================

  defp encode_payload(payload) when is_binary(payload), do: payload

  defp encode_payload(payload) when is_map(payload) do
    Jason.encode!(payload)
  end

  defp decode_payload(type, payload) when type in [:pty_input, :pty_output] do
    # Raw binary payload for PTY I/O
    payload
  end

  defp decode_payload(:pty_resize, <<cols::16-big, rows::16-big>>) do
    %{cols: cols, rows: rows}
  end

  defp decode_payload(:pty_exit, <<exit_code::32-signed-big>>) do
    %{exit_code: exit_code}
  end

  defp decode_payload(:pty_kill, <<signal::8>>) do
    %{signal: signal}
  end

  defp decode_payload(_type, payload) when byte_size(payload) == 0 do
    %{}
  end

  defp decode_payload(_type, payload) do
    case Jason.decode(payload) do
      {:ok, decoded} -> decoded
      {:error, _} -> payload
    end
  end

  # ============================================================================
  # Agent -> Server Messages (JSON)
  # ============================================================================

  @doc """
  Creates a REGISTER message sent when agent connects to server.
  """
  @spec register_message(String.t(), String.t(), [atom()], String.t()) :: message()
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
  Creates an AUTH_REQUEST message for initial authentication.
  """
  @spec auth_request_message(String.t(), map()) :: message()
  def auth_request_message(token, metadata) do
    %{
      type: "auth_request",
      token: token,
      metadata: metadata,
      timestamp: System.system_time(:millisecond)
    }
  end

  @doc """
  Creates an AUTH_RESPONSE message from the server.
  """
  @spec auth_response_message(:ok | :error, String.t() | nil, map()) :: message()
  def auth_response_message(status, agent_id, config) do
    %{
      type: "auth_response",
      status: to_string(status),
      agent_id: agent_id,
      config: config,
      timestamp: System.system_time(:millisecond)
    }
  end

  @doc """
  Creates a PTY_OUTPUT message containing terminal output data.
  """
  @spec pty_output_message(String.t(), binary()) :: message()
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
  @spec pty_created_message(String.t(), String.t(), map(), non_neg_integer()) :: message()
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
  @spec pty_closed_message(String.t(), integer() | nil, term()) :: message()
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
  @spec pty_resized_message(String.t(), pos_integer(), pos_integer()) :: message()
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
  @spec error_message(String.t(), String.t(), String.t() | nil) :: message()
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
  @spec heartbeat_message(non_neg_integer()) :: message()
  def heartbeat_message(active_sessions) do
    %{
      type: "heartbeat",
      active_sessions: active_sessions,
      timestamp: System.system_time(:millisecond)
    }
  end

  @doc """
  Creates a METADATA message with agent information.
  """
  @spec metadata_message(map()) :: message()
  def metadata_message(metadata) do
    %{
      type: "metadata",
      metadata: metadata,
      timestamp: System.system_time(:millisecond)
    }
  end

  # ============================================================================
  # Server -> Agent Messages (Parsing)
  # ============================================================================

  @doc """
  Parses incoming messages from server and validates structure.
  """
  @spec parse_message(map()) :: {:ok, message_type(), map()} | {:error, term()}
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

      %{"type" => "pty_spawn"} = msg ->
        parse_pty_spawn(msg)

      %{"type" => "pty_kill"} = msg ->
        parse_pty_kill(msg)

      %{"type" => "auth_request"} = msg ->
        parse_auth_request(msg)

      %{"type" => "heartbeat"} = msg ->
        {:ok, :heartbeat, %{timestamp: msg["timestamp"]}}

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

  defp parse_pty_spawn(
         %{
           "pty_id" => pty_id
         } = msg
       ) do
    command = msg["command"] || msg["shell"] || System.get_env("SHELL") || "/bin/bash"
    dimensions = msg["dimensions"] || %{"rows" => 24, "cols" => 80}
    env_vars = msg["env"] || %{}
    working_dir = msg["working_dir"]

    {:ok, :pty_spawn,
     %{
       pty_id: pty_id,
       command: command,
       dimensions: dimensions,
       env_vars: env_vars,
       working_dir: working_dir
     }}
  end

  defp parse_pty_spawn(_), do: {:error, :invalid_pty_spawn_message}

  defp parse_close_pty(%{"session_id" => session_id} = msg) do
    force = msg["force"] || false
    {:ok, :close_pty, %{session_id: session_id, force: force}}
  end

  defp parse_close_pty(_), do: {:error, :invalid_close_pty_message}

  defp parse_pty_kill(%{"pty_id" => pty_id} = msg) do
    signal = msg["signal"] || 15
    {:ok, :pty_kill, %{pty_id: pty_id, signal: signal}}
  end

  defp parse_pty_kill(_), do: {:error, :invalid_pty_kill_message}

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

  defp parse_auth_request(%{"token" => token} = msg) do
    metadata = msg["metadata"] || %{}
    {:ok, :auth_request, %{token: token, metadata: metadata}}
  end

  defp parse_auth_request(_), do: {:error, :invalid_auth_request_message}

  # ============================================================================
  # JSON Encoding/Decoding
  # ============================================================================

  @doc """
  Encodes a message to JSON for transmission.
  """
  @spec encode(message()) :: {:ok, String.t()} | {:error, term()}
  def encode(message) when is_map(message) do
    Jason.encode(message)
  end

  @doc """
  Decodes a JSON message from the wire.
  """
  @spec decode(String.t()) :: {:ok, message_type(), map()} | {:error, term()}
  def decode(json_string) when is_binary(json_string) do
    case Jason.decode(json_string) do
      {:ok, decoded} -> parse_message(decoded)
      {:error, reason} -> {:error, {:json_decode_error, reason}}
    end
  end

  @doc """
  Validates message structure and required fields.
  """
  @spec validate_message(message()) :: {:ok, message()} | {:error, term()}
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
  @spec generate_session_id(String.t()) :: String.t()
  def generate_session_id(agent_name) do
    timestamp = System.system_time(:millisecond)
    random_hex = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    "#{agent_name}_#{timestamp}_#{random_hex}"
  end

  @doc """
  Generates a unique PTY ID (16-bit unsigned integer).
  """
  @spec generate_pty_id() :: non_neg_integer()
  def generate_pty_id do
    :rand.uniform(65535)
  end
end
