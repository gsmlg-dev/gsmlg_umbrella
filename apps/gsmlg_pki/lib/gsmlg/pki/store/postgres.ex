defmodule GSMLG.PKI.Store.Postgres do
  @moduledoc """
  PostgreSQL adapter for PKI event storage using Ecto.

  This module provides the same interface as the CouchDB store but uses
  PostgreSQL for better query performance, ACID guarantees, and simpler
  infrastructure management.

  ## Configuration

      config :gsmlg_pki, GSMLG.PKI.Store.Postgres,
        repo: GSMLG.Repo

  ## Database Setup

  The database schema is managed through Ecto migrations. Run migrations
  to set up the pki_events table:

      mix ecto.migrate

  """

  import Ecto.Query
  alias GSMLG.Repo
  alias GSMLG.PKI.Schema.Event

  @doc """
  Store a new event in PostgreSQL.

  ## Parameters

  - `event` - Event map from GSMLG.PKI.Events

  ## Examples

      {:ok, event} = GSMLG.PKI.Store.Postgres.store_event(event)
  """
  @spec store_event(map()) :: {:ok, map()} | {:error, term()}
  def store_event(event) do
    changeset =
      %Event{}
      |> Event.changeset(%{
        id: event.id,
        event_type: event.event_type,
        timestamp: event.timestamp,
        sequence: event.sequence,
        ca_id: event.ca_id,
        metadata: event.metadata || %{},
        actor: Map.get(event, :actor),
        correlation_id: Map.get(event, :correlation_id)
      })

    case Repo.insert(changeset) do
      {:ok, stored_event} ->
        {:ok, Event.to_pki_event(stored_event)}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        GSMLG.Telemetry.error(
          "Failed to store PKI event",
          %{
            event_type: event.event_type,
            ca_id: event.ca_id,
            errors: inspect(errors)
          }
        )

        {:error, changeset}

      {:error, reason} ->
        GSMLG.Telemetry.error(
          "Failed to store PKI event",
          %{
            event_type: event.event_type,
            ca_id: event.ca_id,
            error: inspect(reason)
          }
        )

        {:error, reason}
    end
  end

  @doc """
  Query events by CA identifier.

  ## Parameters

  - `ca_id` - The CA identifier
  - `opts` - Query options:
    - `:limit` - Maximum number of results
    - `:start_sequence` - Start from this sequence
    - `:end_sequence` - End at this sequence
    - `:descending` - Return results in descending order (default: false)

  ## Examples

      {:ok, events} = GSMLG.PKI.Store.Postgres.query_events_by_ca("ca:root")
      {:ok, recent} = GSMLG.PKI.Store.Postgres.query_events_by_ca("ca:root",
        limit: 10,
        descending: true
      )
  """
  @spec query_events_by_ca(String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def query_events_by_ca(ca_id, opts \\ []) do
    limit = Keyword.get(opts, :limit)
    start_seq = Keyword.get(opts, :start_sequence)
    end_seq = Keyword.get(opts, :end_sequence)
    descending = Keyword.get(opts, :descending, false)

    query =
      from e in Event,
        where: e.ca_id == ^ca_id

    query =
      if start_seq do
        from e in query, where: e.sequence >= ^start_seq
      else
        query
      end

    query =
      if end_seq do
        from e in query, where: e.sequence <= ^end_seq
      else
        query
      end

    query =
      if descending do
        from e in query, order_by: [desc: e.sequence]
      else
        from e in query, order_by: [asc: e.sequence]
      end

    query =
      if limit do
        from e in query, limit: ^limit
      else
        query
      end

    events =
      query
      |> Repo.all()
      |> Enum.map(&Event.to_pki_event/1)

    {:ok, events}
  rescue
    error ->
      GSMLG.Telemetry.error(
        "Failed to query events by CA",
        %{ca_id: ca_id, error: inspect(error)}
      )

      {:error, error}
  end

  @doc """
  Query events by event type.

  ## Parameters

  - `event_type` - The event type atom
  - `opts` - Query options:
    - `:limit` - Maximum number of results
    - `:start_time` - Start from this timestamp
    - `:end_time` - End at this timestamp

  ## Examples

      {:ok, revocations} = GSMLG.PKI.Store.Postgres.query_events_by_type(:certificate_revoked)
  """
  @spec query_events_by_type(atom(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def query_events_by_type(event_type, opts \\ []) do
    limit = Keyword.get(opts, :limit)
    start_time = Keyword.get(opts, :start_time)
    end_time = Keyword.get(opts, :end_time)

    query =
      from e in Event,
        where: e.event_type == ^event_type,
        order_by: [asc: e.timestamp]

    query =
      if start_time do
        from e in query, where: e.timestamp >= ^start_time
      else
        query
      end

    query =
      if end_time do
        from e in query, where: e.timestamp <= ^end_time
      else
        query
      end

    query =
      if limit do
        from e in query, limit: ^limit
      else
        query
      end

    events =
      query
      |> Repo.all()
      |> Enum.map(&Event.to_pki_event/1)

    {:ok, events}
  rescue
    error ->
      GSMLG.Telemetry.error(
        "Failed to query events by type",
        %{event_type: event_type, error: inspect(error)}
      )

      {:error, error}
  end

  @doc """
  Query events by certificate serial number.

  ## Parameters

  - `serial` - Certificate serial number

  ## Examples

      {:ok, events} = GSMLG.PKI.Store.Postgres.query_events_by_serial(12345)
  """
  @spec query_events_by_serial(non_neg_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def query_events_by_serial(serial) do
    # Use JSONB query for metadata->>'serial'
    query =
      from e in Event,
        where: fragment("?->>'serial' = ?", e.metadata, ^to_string(serial)),
        order_by: [asc: e.timestamp]

    events =
      query
      |> Repo.all()
      |> Enum.map(&Event.to_pki_event/1)

    {:ok, events}
  rescue
    error ->
      GSMLG.Telemetry.error(
        "Failed to query events by serial",
        %{serial: serial, error: inspect(error)}
      )

      {:error, error}
  end

  @doc """
  Set up the PostgreSQL database schema.

  For PostgreSQL, this is handled by Ecto migrations. This function
  is provided for API compatibility with the CouchDB adapter and
  is a no-op.

  ## Examples

      :ok = GSMLG.PKI.Store.Postgres.setup()
  """
  @spec setup() :: :ok
  def setup do
    GSMLG.Telemetry.info(
      "PKI PostgreSQL store is ready (schema managed by migrations)",
      %{}
    )

    :ok
  end

  @doc """
  Get storage statistics.

  Returns statistics about the PKI event storage including total events,
  events by type, and storage size information.

  ## Examples

      {:ok, stats} = GSMLG.PKI.Store.Postgres.get_stats()
  """
  @spec get_stats() :: {:ok, map()} | {:error, term()}
  def get_stats do
    total_events_query = from e in Event, select: count(e.id)
    total_events = Repo.one(total_events_query)

    events_by_type_query =
      from e in Event,
        group_by: e.event_type,
        select: {e.event_type, count(e.id)}

    events_by_type = Repo.all(events_by_type_query) |> Map.new()

    stats = %{
      total_events: total_events,
      events_by_type: events_by_type,
      storage_backend: :postgres
    }

    {:ok, stats}
  rescue
    error ->
      GSMLG.Telemetry.error(
        "Failed to get storage stats",
        %{error: inspect(error)}
      )

      {:error, error}
  end
end
