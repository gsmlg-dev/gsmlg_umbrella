defmodule GSMLG.PKI.Store.CouchDB do
  @moduledoc """
  CouchDB adapter for PKI event storage.

  This module provides low-level operations for storing and querying
  PKI events in CouchDB. It handles serialization, indexing, and
  query optimization.

  ## Configuration

      config :gsmlg_pki, GSMLG.PKI.Store.CouchDB,
        database: "pki_events",
        connection: GSMLG.CouchDB.Connection

  ## Database Setup

  The database and indexes are automatically created when the application starts.
  Use `GSMLG.PKI.Store.CouchDB.setup/0` to manually initialize the database.
  """

  # Suppress undefined module warnings for CouchDB modules
  @compile {:no_warn_undefined, [GSMLG.CouchDB.DB, GSMLG.CouchDB.Docs]}

  alias GSMLG.CouchDB.{DB, Docs}

  @database Application.compile_env(:gsmlg_pki, [__MODULE__, :database], "pki_events")

  @doc """
  Store a new event in CouchDB.

  ## Parameters

  - `event` - Event map from GSMLG.PKI.Events

  ## Examples

      {:ok, doc} = GSMLG.PKI.Store.CouchDB.store_event(event)
  """
  @spec store_event(map()) :: {:ok, map()} | {:error, term()}
  def store_event(event) do
    doc = event_to_document(event)

    case Docs.create_doc(@database, doc) do
      {:ok, response} ->
        {:ok, Map.put(doc, "_rev", response["rev"])}

      {:error, reason} ->
        GSMLG.Telemetry.log(
          :error,
          "Failed to store PKI event",
          metadata: %{
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
    - `:descending` - Return results in descending order

  ## Examples

      {:ok, events} = GSMLG.PKI.Store.CouchDB.query_events_by_ca("ca:root")
      {:ok, recent} = GSMLG.PKI.Store.CouchDB.query_events_by_ca("ca:root",
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

    selector = %{
      "type" => "pki_event",
      "ca_id" => ca_id
    }

    selector =
      if start_seq || end_seq do
        range_selector = %{}

        range_selector =
          if start_seq,
            do: Map.put(range_selector, "$gte", start_seq),
            else: range_selector

        range_selector =
          if end_seq,
            do: Map.put(range_selector, "$lte", end_seq),
            else: range_selector

        Map.put(selector, "sequence", range_selector)
      else
        selector
      end

    query_params = %{
      selector: selector,
      sort: [
        %{
          "ca_id" => if(descending, do: "desc", else: "asc"),
          "sequence" => if(descending, do: "desc", else: "asc")
        }
      ]
    }

    query_params = if limit, do: Map.put(query_params, :limit, limit), else: query_params

    case Docs.find(@database, query_params) do
      {:ok, %{"docs" => docs}} ->
        events = Enum.map(docs, &document_to_event/1)
        {:ok, events}

      {:error, reason} ->
        {:error, reason}
    end
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

      {:ok, revocations} = GSMLG.PKI.Store.CouchDB.query_events_by_type(:certificate_revoked)
  """
  @spec query_events_by_type(atom(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def query_events_by_type(event_type, opts \\ []) do
    limit = Keyword.get(opts, :limit)
    start_time = Keyword.get(opts, :start_time)
    end_time = Keyword.get(opts, :end_time)

    selector = %{
      "type" => "pki_event",
      "event_type" => Atom.to_string(event_type)
    }

    selector =
      if start_time || end_time do
        range_selector = %{}

        range_selector =
          if start_time,
            do: Map.put(range_selector, "$gte", DateTime.to_iso8601(start_time)),
            else: range_selector

        range_selector =
          if end_time,
            do: Map.put(range_selector, "$lte", DateTime.to_iso8601(end_time)),
            else: range_selector

        Map.put(selector, "timestamp", range_selector)
      else
        selector
      end

    query_params = %{
      selector: selector,
      sort: [%{"event_type" => "asc", "timestamp" => "asc"}]
    }

    query_params = if limit, do: Map.put(query_params, :limit, limit), else: query_params

    case Docs.find(@database, query_params) do
      {:ok, %{"docs" => docs}} ->
        events = Enum.map(docs, &document_to_event/1)
        {:ok, events}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Query events by certificate serial number.

  ## Parameters

  - `serial` - Certificate serial number

  ## Examples

      {:ok, events} = GSMLG.PKI.Store.CouchDB.query_events_by_serial(12345)
  """
  @spec query_events_by_serial(non_neg_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def query_events_by_serial(serial) do
    selector = %{
      "type" => "pki_event",
      "metadata.serial" => serial
    }

    query_params = %{
      selector: selector,
      sort: [%{"timestamp" => "asc"}]
    }

    case Docs.find(@database, query_params) do
      {:ok, %{"docs" => docs}} ->
        events = Enum.map(docs, &document_to_event/1)
        {:ok, events}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Set up the CouchDB database and indexes.

  Creates the database if it doesn't exist and ensures all necessary
  indexes are created for efficient querying.

  ## Examples

      :ok = GSMLG.PKI.Store.CouchDB.setup()
  """
  @spec setup() :: :ok | {:error, term()}
  def setup do
    GSMLG.Telemetry.log(:info, "Setting up PKI CouchDB database",
      metadata: %{database: @database}
    )

    # Create database
    case DB.create_db(@database) do
      {:ok, _} ->
        GSMLG.Telemetry.log(:info, "Created PKI database", metadata: %{database: @database})

      {:error, %{"error" => "file_exists"}} ->
        GSMLG.Telemetry.log(:debug, "PKI database already exists",
          metadata: %{database: @database}
        )

      {:error, reason} ->
        GSMLG.Telemetry.log(:error, "Failed to create PKI database",
          metadata: %{database: @database, error: inspect(reason)}
        )

        {:error, reason}
    end

    # Create indexes
    with :ok <- create_ca_sequence_index(),
         :ok <- create_event_type_index(),
         :ok <- create_serial_index(),
         :ok <- create_timestamp_index() do
      GSMLG.Telemetry.log(:info, "PKI CouchDB setup completed successfully")
      :ok
    else
      {:error, reason} ->
        GSMLG.Telemetry.log(:error, "Failed to create PKI indexes",
          metadata: %{error: inspect(reason)}
        )

        {:error, reason}
    end
  end

  @doc """
  Get database statistics.

  Returns information about the database size, document count, etc.

  ## Examples

      {:ok, stats} = GSMLG.PKI.Store.CouchDB.get_stats()
  """
  @spec get_stats() :: {:ok, map()} | {:error, term()}
  def get_stats do
    DB.info_db(@database)
  end

  # Private Functions

  defp event_to_document(event) do
    %{
      "_id" => event.id,
      "type" => "pki_event",
      "event_type" => Atom.to_string(event.event_type),
      "timestamp" => DateTime.to_iso8601(event.timestamp),
      "sequence" => event.sequence,
      "ca_id" => event.ca_id,
      "metadata" => serialize_metadata(event.metadata),
      "actor" => event[:actor],
      "correlation_id" => event[:correlation_id]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp document_to_event(doc) do
    %{
      id: doc["_id"],
      rev: doc["_rev"],
      type: :pki_event,
      event_type: String.to_existing_atom(doc["event_type"]),
      timestamp: parse_timestamp(doc["timestamp"]),
      sequence: doc["sequence"],
      ca_id: doc["ca_id"],
      metadata: deserialize_metadata(doc["metadata"]),
      actor: doc["actor"],
      correlation_id: doc["correlation_id"]
    }
  end

  defp serialize_metadata(metadata) do
    metadata
    |> Enum.map(fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), serialize_value(v)}
      {k, v} -> {k, serialize_value(v)}
    end)
    |> Map.new()
  end

  defp serialize_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_value(binary) when is_binary(binary), do: Base.encode64(binary)
  defp serialize_value(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp serialize_value(list) when is_list(list), do: Enum.map(list, &serialize_value/1)
  defp serialize_value(map) when is_map(map), do: serialize_metadata(map)
  defp serialize_value(value), do: value

  defp deserialize_metadata(nil), do: %{}

  defp deserialize_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.map(fn {k, v} ->
      # Try to convert keys that look like atoms
      key = try_to_atom(k)
      {key, deserialize_value(k, v)}
    end)
    |> Map.new()
  end

  defp deserialize_value(key, value) when is_binary(value) do
    cond do
      String.ends_with?(key, "_der") or String.ends_with?(key, "_key") ->
        # Binary data encoded as base64
        case Base.decode64(value) do
          {:ok, binary} -> binary
          :error -> value
        end

      String.ends_with?(key, "_date") or String.ends_with?(key, "_time") or
          key in ["timestamp", "not_before", "not_after"] ->
        # Timestamp strings
        case DateTime.from_iso8601(value) do
          {:ok, dt, _} -> dt
          {:error, _} -> value
        end

      true ->
        value
    end
  end

  defp deserialize_value(_key, list) when is_list(list) do
    Enum.map(list, fn
      v when is_map(v) -> deserialize_metadata(v)
      v -> v
    end)
  end

  defp deserialize_value(_key, map) when is_map(map) do
    deserialize_metadata(map)
  end

  defp deserialize_value(_key, value), do: value

  defp try_to_atom(str) when is_binary(str) do
    try do
      String.to_existing_atom(str)
    rescue
      ArgumentError -> str
    end
  end

  defp try_to_atom(val), do: val

  defp parse_timestamp(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end

  defp parse_timestamp(_), do: nil

  # Index creation helpers

  defp create_ca_sequence_index do
    index = %{
      "index" => %{
        "fields" => ["ca_id", "sequence"]
      },
      "name" => "ca-sequence-index",
      "type" => "json"
    }

    case Docs.create_index(@database, index) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_event_type_index do
    index = %{
      "index" => %{
        "fields" => ["event_type", "timestamp"]
      },
      "name" => "event-type-index",
      "type" => "json"
    }

    case Docs.create_index(@database, index) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_serial_index do
    index = %{
      "index" => %{
        "fields" => ["metadata.serial", "timestamp"]
      },
      "name" => "serial-index",
      "type" => "json"
    }

    case Docs.create_index(@database, index) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_timestamp_index do
    index = %{
      "index" => %{
        "fields" => ["timestamp"]
      },
      "name" => "timestamp-index",
      "type" => "json"
    }

    case Docs.create_index(@database, index) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
