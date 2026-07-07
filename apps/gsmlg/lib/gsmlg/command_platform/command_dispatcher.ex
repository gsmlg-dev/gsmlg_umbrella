defmodule GSMLG.CommandPlatform.CommandDispatcher do
  @moduledoc """
  Dispatches PTY commands to agents.

  Provides a clean API for sending commands from the admin UI to PTY agents,
  with validation, audit logging, and error handling.
  """

  require Logger
  alias GSMLG.CommandPlatform.{AgentRegistry, PTYSessionRecord, SessionTracker}

  @doc """
  Creates a new PTY session on a specific agent.
  """
  def create_pty(agent_id, opts \\ []) do
    with :ok <- validate_agent(agent_id),
         {:ok, params} <- build_create_params(agent_id, opts) do
      audit_log(:create_pty, agent_id, params)

      case AgentRegistry.send_to_agent(agent_id, {:create_pty, params}) do
        :ok ->
          track_initial_session(agent_id, params)
          {:ok, params.session_id}

        {:error, reason} ->
          PTYSessionRecord.delete(params.session_id)

          GSMLG.Telemetry.error("Failed to dispatch create_pty command",
            metadata: %{
              agent_id: agent_id,
              reason: inspect(reason)
            }
          )

          {:error, reason}
      end
    end
  end

  @doc """
  Closes a PTY session.
  """
  def close_pty(session_id, force \\ false, opts \\ []) do
    with {:ok, agent_id} <- resolve_session_agent(session_id, opts),
         :ok <- validate_agent(agent_id) do
      audit_log(:close_pty, agent_id, %{session_id: session_id, force: force})

      AgentRegistry.send_to_agent(agent_id, {:close_pty, session_id, force})
    end
  end

  @doc """
  Attaches a controller to a PTY session.
  """
  def attach_pty(session_id, controller_pid, opts \\ []) do
    with {:ok, agent_id} <- resolve_session_agent(session_id, opts),
         :ok <- validate_agent(agent_id) do
      SessionTracker.set_controller(session_id, controller_pid)
      audit_log(:attach_pty, agent_id, %{session_id: session_id})

      AgentRegistry.send_to_agent(agent_id, {:attach_pty, session_id})
    end
  end

  @doc """
  Detaches the controller from a PTY session.
  """
  def detach_pty(session_id, opts \\ []) do
    with {:ok, agent_id} <- resolve_session_agent(session_id, opts),
         :ok <- validate_agent(agent_id) do
      SessionTracker.clear_controller(session_id)
      audit_log(:detach_pty, agent_id, %{session_id: session_id})

      AgentRegistry.send_to_agent(agent_id, {:detach_pty, session_id})
    end
  end

  @doc """
  Sends input data to a PTY session.
  """
  def send_input(session_id, data, opts \\ []) do
    with {:ok, agent_id} <- resolve_session_agent(session_id, opts),
         :ok <- validate_agent(agent_id),
         :ok <- validate_input(data) do
      AgentRegistry.send_to_agent(agent_id, {:send_input, session_id, data})
    end
  end

  @doc """
  Resizes a PTY session.
  """
  def resize_pty(session_id, rows, cols, opts \\ []) do
    with {:ok, agent_id} <- resolve_session_agent(session_id, opts),
         :ok <- validate_agent(agent_id),
         :ok <- validate_dimensions(rows, cols) do
      audit_log(:resize_pty, agent_id, %{
        session_id: session_id,
        rows: rows,
        cols: cols
      })

      AgentRegistry.send_to_agent(agent_id, {:resize_pty, session_id, rows, cols})
    end
  end

  @doc """
  Lists all sessions on a specific agent.
  """
  def list_agent_sessions(agent_id) do
    with :ok <- validate_agent(agent_id) do
      AgentRegistry.send_to_agent(agent_id, {:list_sessions})
    end
  end

  @doc """
  Sends a command to a specific agent with validation.
  """
  def dispatch(agent_id, command_type, params) do
    with :ok <- validate_agent(agent_id),
         :ok <- validate_command(command_type, params) do
      audit_log(command_type, agent_id, params)

      AgentRegistry.send_to_agent(agent_id, {command_type, params})
    end
  end

  # Validation Functions

  defp validate_agent(agent_id) do
    if AgentRegistry.agent_connected?(agent_id) do
      :ok
    else
      {:error, :agent_not_connected}
    end
  end

  defp resolve_session_agent(session_id, opts) do
    case Keyword.get(opts, :agent_id) do
      agent_id when is_binary(agent_id) and agent_id != "" ->
        {:ok, agent_id}

      _ ->
        case SessionTracker.find_session(session_id) do
          {:ok, session} -> {:ok, session.agent_id}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp build_create_params(agent_id, opts) do
    command = Keyword.get(opts, :command)
    dimensions = Keyword.get(opts, :dimensions, %{rows: 24, cols: 80})
    env_vars = Keyword.get(opts, :env_vars, %{})
    working_dir = Keyword.get(opts, :working_dir)

    with :ok <- validate_command_string(command),
         :ok <- validate_dimensions(dimensions.rows, dimensions.cols) do
      session_id = generate_session_id(agent_id)

      params = %{
        session_id: session_id,
        command: command,
        dimensions: dimensions,
        env_vars: env_vars,
        working_dir: working_dir
      }

      {:ok, params}
    end
  end

  defp validate_command_string(nil), do: {:error, :command_required}

  defp validate_command_string(command) when is_binary(command) do
    cond do
      String.trim(command) == "" ->
        {:error, :empty_command}

      String.length(command) > 10_000 ->
        {:error, :command_too_long}

      # Check for potentially dangerous patterns
      dangerous_pattern?(command) ->
        GSMLG.Telemetry.warn("Potentially dangerous command detected",
          metadata: %{
            command: command
          }
        )

        {:error, :dangerous_command}

      true ->
        :ok
    end
  end

  defp validate_command_string(_), do: {:error, :invalid_command_type}

  defp validate_input(data) when is_binary(data) do
    if byte_size(data) > 1_048_576 do
      {:error, :input_too_large}
    else
      :ok
    end
  end

  defp validate_input(_), do: {:error, :invalid_input_type}

  defp validate_dimensions(rows, cols)
       when is_integer(rows) and is_integer(cols) and rows > 0 and cols > 0 and rows <= 1000 and
              cols <= 1000 do
    :ok
  end

  defp validate_dimensions(_rows, _cols), do: {:error, :invalid_dimensions}

  defp validate_command(:create_pty, %{command: command}) do
    validate_command_string(command)
  end

  defp validate_command(:close_pty, %{session_id: session_id}) when is_binary(session_id), do: :ok

  defp validate_command(:attach_pty, %{session_id: session_id}) when is_binary(session_id),
    do: :ok

  defp validate_command(:detach_pty, %{session_id: session_id}) when is_binary(session_id),
    do: :ok

  defp validate_command(:send_input, %{session_id: session_id, data: data})
       when is_binary(session_id) and is_binary(data) do
    validate_input(data)
  end

  defp validate_command(:resize_pty, %{session_id: session_id, rows: rows, cols: cols})
       when is_binary(session_id) do
    validate_dimensions(rows, cols)
  end

  defp validate_command(_type, _params), do: {:error, :invalid_command}

  # Security: Check for dangerous command patterns
  defp dangerous_pattern?(command) do
    dangerous_patterns = [
      # Format all drives/disks
      ~r/rm\s+-rf\s+\//,
      # Fork bomb
      ~r/:\(\)\{.*:\|:.*\}/,
      # Kernel panic
      ~r/echo\s+[^\s]+\s*>\s*\/proc\/sysrq-trigger/,
      # Override important system files
      ~r/>\s*\/etc\/(passwd|shadow|sudoers)/
    ]

    Enum.any?(dangerous_patterns, fn pattern ->
      Regex.match?(pattern, command)
    end)
  end

  defp generate_session_id(agent_id) do
    timestamp = System.system_time(:millisecond)
    random_hex = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    "#{agent_id}_#{timestamp}_#{random_hex}"
  end

  defp track_initial_session(agent_id, params) do
    SessionTracker.register_session_async(agent_id, params.session_id, %{
      command: params.command,
      dimensions: params.dimensions,
      state: :initializing,
      metadata: %{requested_at: System.system_time(:millisecond)}
    })
  end

  # Audit Logging

  defp audit_log(command_type, agent_id, params) do
    GSMLG.Telemetry.info("PTY command dispatched",
      metadata: %{
        command_type: command_type,
        agent_id: agent_id,
        params: inspect(params),
        timestamp: System.system_time(:millisecond)
      }
    )

    # Store in audit log table (if needed)
    # GSMLG.CommandPlatform.AuditLog.log(command_type, agent_id, params)
  end
end
