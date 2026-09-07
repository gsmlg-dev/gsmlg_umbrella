defmodule GSMLG.Commander.Protocol.JobEvent do
  @moduledoc "A sequenced progress event for a remote execution."

  alias GSMLG.Commander.Protocol.{Constants, Validation}

  @enforce_keys [:protocol_version, :remote_execution_id, :sequence, :event]
  defstruct @enforce_keys ++ [phase: nil, metadata: nil, occurred_at: nil]

  @type t :: %__MODULE__{
          protocol_version: pos_integer(),
          remote_execution_id: String.t(),
          sequence: pos_integer(),
          event: String.t(),
          phase: String.t() | nil,
          metadata: map() | nil,
          occurred_at: String.t() | nil
        }

  @required ~w(type protocol_version remote_execution_id sequence event)
  @optional ~w(phase metadata occurred_at)
  @metadata_keys ~w(central_job_id artifact_id content_hash reason code duration_ms payload_size status phase)
  @max_metadata_bytes 4_096

  def decode(map) do
    with :ok <- Validation.fields(map, @required, @optional),
         :ok <- Validation.protocol_version(map["protocol_version"]),
         :ok <- Validation.uuid(map["remote_execution_id"], "remote_execution_id"),
         :ok <- Validation.positive_integer(map["sequence"], "sequence"),
         :ok <- Validation.one_of(map["event"], Constants.workflow_events(), "event"),
         :ok <- Validation.optional_nonempty_string(map["phase"], "phase"),
         :ok <- event_metadata(map["metadata"]),
         :ok <- optional_timestamp(map["occurred_at"], "occurred_at") do
      {:ok,
       %__MODULE__{
         protocol_version: map["protocol_version"],
         remote_execution_id: map["remote_execution_id"],
         sequence: map["sequence"],
         event: map["event"],
         phase: map["phase"],
         metadata: map["metadata"],
         occurred_at: map["occurred_at"]
       }}
    end
  end

  def encode(%__MODULE__{} = event) do
    map = %{
      "type" => "job.event",
      "protocol_version" => event.protocol_version,
      "remote_execution_id" => event.remote_execution_id,
      "sequence" => event.sequence,
      "event" => event.event
    }

    map = put_optional(map, "phase", event.phase)
    map = put_optional(map, "metadata", event.metadata)
    map = put_optional(map, "occurred_at", event.occurred_at)

    with {:ok, _validated} <- decode(map), do: {:ok, map}
  end

  defp event_metadata(%{"central_job_id" => central_job_id} = metadata) do
    unknown = Map.keys(metadata) -- @metadata_keys

    cond do
      unknown != [] ->
        Validation.invalid("unknown_event_metadata", %{"fields" => Enum.sort(unknown)})

      map_size(metadata) > length(@metadata_keys) ->
        Validation.invalid("event_metadata_too_large", %{})

      true ->
        with :ok <- Validation.uuid(central_job_id, "central_job_id"),
             :ok <- validate_metadata_values(metadata),
             {:ok, size} <- Validation.encoded_size(metadata) do
          if size <= @max_metadata_bytes,
            do: :ok,
            else: Validation.invalid("event_metadata_too_large", %{})
        end
    end
  end

  defp event_metadata(_metadata), do: Validation.invalid("invalid_event_metadata", %{})

  defp validate_metadata_values(metadata) do
    Enum.reduce_while(metadata, :ok, fn
      {key, value}, :ok when key in ~w(duration_ms payload_size) ->
        case Validation.nonnegative_integer(value, key) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      {key, value}, :ok ->
        case Validation.bounded_string(value, key, 256) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
    end)
  end

  defp optional_timestamp(nil, _field), do: :ok
  defp optional_timestamp(value, field), do: Validation.timestamp(value, field)

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
