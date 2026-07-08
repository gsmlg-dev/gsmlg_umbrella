defmodule GSMLG.CommandPlatform.PTYSessionRecord do
  @moduledoc """
  Concord-backed record definition for PTY sessions.

  Stores PTY session metadata for tracking across agent reconnections.
  """

  @key_prefix "command_platform:pty_sessions:"

  defstruct [
    :session_id,
    :agent_id,
    :command,
    :dimensions,
    :created_at,
    :last_activity,
    :state,
    :exit_code,
    :controller_pid,
    :metadata
  ]

  @type t :: %__MODULE__{
          session_id: String.t(),
          agent_id: String.t(),
          command: String.t(),
          dimensions: %{rows: integer(), cols: integer()},
          created_at: integer(),
          last_activity: integer(),
          state: :initializing | :running | :attached | :detached | :closing | :closed,
          exit_code: integer() | nil,
          controller_pid: pid() | nil,
          metadata: map()
        }

  @doc """
  Ensures the local Concord store is available for PTY sessions.

  Kept as `create_table/0` so older setup paths can call it while the backing
  store is Concord instead of Mnesia.
  """
  def create_table, do: ensure_store()

  @doc """
  Inserts or updates a session record.
  """
  def write(session) when is_map(session) do
    record = map_to_record(session)

    with :ok <- validate_session_id(record.session_id),
         :ok <- ensure_store() do
      case Concord.Local.put(key(record.session_id), record) do
        :ok ->
          :ok

        {:ok, _} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Reads a session by ID.
  """
  def read(session_id) do
    with :ok <- validate_session_id(session_id),
         :ok <- ensure_store() do
      case Concord.Local.get(key(session_id)) do
        {:ok, record} -> {:ok, map_to_record(record)}
        {:error, :not_found} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
        nil -> {:error, :not_found}
      end
    end
  end

  @doc """
  Deletes a session record.
  """
  def delete(session_id) do
    with :ok <- validate_session_id(session_id),
         :ok <- ensure_store() do
      case Concord.Local.delete(key(session_id)) do
        :ok -> :ok
        {:ok, _} -> :ok
        {:error, :not_found} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Lists all sessions, optionally filtered by agent_id or state.
  """
  def list(opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)
    state_filter = Keyword.get(opts, :state)

    case all_records() do
      {:ok, records} ->
        Enum.filter(records, fn record ->
          matches_filter?(record.agent_id, agent_id) and
            matches_filter?(record.state, state_filter)
        end)

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Counts sessions, optionally filtered.
  """
  def count(opts \\ []) do
    list(opts) |> length()
  end

  @doc """
  Cleans up old closed sessions.
  """
  def cleanup_old_sessions(max_age_ms \\ :timer.hours(24)) do
    now = System.system_time(:millisecond)
    cutoff = now - max_age_ms

    list(state: :closed)
    |> Enum.filter(&(&1.last_activity < cutoff))
    |> Enum.each(&delete(&1.session_id))

    :ok
  end

  # Private Functions

  defp ensure_store do
    case Process.whereis(Concord.Engine.Local) do
      nil ->
        case Concord.Engine.Local.start_link([]) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _pid ->
        :ok
    end
  end

  defp all_records do
    with :ok <- ensure_store() do
      case Concord.Local.prefix_scan(@key_prefix) do
        {:ok, records} -> {:ok, Enum.map(records, fn {_key, record} -> map_to_record(record) end)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp map_to_record(map) do
    %__MODULE__{
      session_id: get_value(map, :session_id),
      agent_id: get_value(map, :agent_id),
      command: get_value(map, :command),
      dimensions: get_value(map, :dimensions) || %{rows: 24, cols: 80},
      created_at: get_value(map, :created_at) || System.system_time(:millisecond),
      last_activity: get_value(map, :last_activity) || System.system_time(:millisecond),
      state: get_value(map, :state) || :running,
      exit_code: get_value(map, :exit_code),
      controller_pid: get_value(map, :controller_pid),
      metadata: get_value(map, :metadata) || %{}
    }
  end

  defp get_value(%__MODULE__{} = record, key), do: Map.get(record, key)

  defp get_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp validate_session_id(session_id) when is_binary(session_id) and session_id != "", do: :ok
  defp validate_session_id(_session_id), do: {:error, :missing_session_id}

  defp key(session_id), do: @key_prefix <> session_id

  defp matches_filter?(_value, nil), do: true
  defp matches_filter?(value, filter), do: value == filter
end
