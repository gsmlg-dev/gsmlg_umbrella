defmodule GSMLG.CommandPlatform.PTYSessionRecord do
  @moduledoc """
  Mnesia record definition for PTY sessions.

  Stores PTY session metadata for persistence and tracking across
  agent reconnections and server restarts.
  """

  require Logger

  @table :pty_sessions

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
          state: :running | :attached | :detached | :closing | :closed,
          exit_code: integer() | nil,
          controller_pid: pid() | nil,
          metadata: map()
        }

  @doc """
  Creates the Mnesia table for PTY sessions.
  """
  def create_table do
    case :mnesia.create_table(@table,
           attributes: [
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
           ],
           disc_copies: [node()],
           type: :set,
           index: [:agent_id, :state]
         ) do
      {:atomic, :ok} ->
        GSMLG.Telemetry.info("Created PTY sessions Mnesia table", metadata: %{})
        :ok

      {:aborted, {:already_exists, @table}} ->
        GSMLG.Telemetry.debug("PTY sessions table already exists", metadata: %{})
        :ok

      {:aborted, reason} ->
        GSMLG.Telemetry.error("Failed to create PTY sessions table",
          metadata: %{
            reason: inspect(reason)
          }
        )

        {:error, reason}
    end
  end

  @doc """
  Inserts or updates a session record.
  """
  def write(session) when is_map(session) do
    record = map_to_record(session)

    :mnesia.transaction(fn ->
      :mnesia.write(@table, record, :write)
    end)
    |> case do
      {:atomic, :ok} -> :ok
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc """
  Reads a session by ID.
  """
  def read(session_id) do
    :mnesia.transaction(fn ->
      :mnesia.read(@table, session_id)
    end)
    |> case do
      {:atomic, [record]} -> {:ok, record_to_map(record)}
      {:atomic, []} -> {:error, :not_found}
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes a session record.
  """
  def delete(session_id) do
    :mnesia.transaction(fn ->
      :mnesia.delete(@table, session_id, :write)
    end)
    |> case do
      {:atomic, :ok} -> :ok
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists all sessions, optionally filtered by agent_id or state.
  """
  def list(opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)
    state_filter = Keyword.get(opts, :state)

    :mnesia.transaction(fn ->
      cond do
        agent_id ->
          :mnesia.index_read(@table, agent_id, :agent_id)

        state_filter ->
          :mnesia.index_read(@table, state_filter, :state)

        true ->
          :mnesia.match_object(
            @table,
            {:pty_sessions, :_, :_, :_, :_, :_, :_, :_, :_, :_, :_},
            :read
          )
      end
    end)
    |> case do
      {:atomic, records} -> Enum.map(records, &record_to_map/1)
      {:aborted, _reason} -> []
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

    :mnesia.transaction(fn ->
      sessions =
        :mnesia.match_object(
          @table,
          {:pty_sessions, :_, :_, :_, :_, :_, :_, :_, :closed, :_, :_, :_},
          :read
        )

      Enum.each(sessions, fn record ->
        session = record_to_map(record)

        if session.last_activity < cutoff do
          :mnesia.delete(@table, session.session_id, :write)
        end
      end)
    end)
  end

  # Private Functions

  defp map_to_record(map) do
    {
      @table,
      Map.get(map, :session_id),
      Map.get(map, :agent_id),
      Map.get(map, :command),
      Map.get(map, :dimensions, %{rows: 24, cols: 80}),
      Map.get(map, :created_at, System.system_time(:millisecond)),
      Map.get(map, :last_activity, System.system_time(:millisecond)),
      Map.get(map, :state, :running),
      Map.get(map, :exit_code),
      Map.get(map, :controller_pid),
      Map.get(map, :metadata, %{})
    }
  end

  defp record_to_map(
         {@table, session_id, agent_id, command, dimensions, created_at, last_activity, state,
          exit_code, controller_pid, metadata}
       ) do
    %__MODULE__{
      session_id: session_id,
      agent_id: agent_id,
      command: command,
      dimensions: dimensions,
      created_at: created_at,
      last_activity: last_activity,
      state: state,
      exit_code: exit_code,
      controller_pid: controller_pid,
      metadata: metadata
    }
  end
end
