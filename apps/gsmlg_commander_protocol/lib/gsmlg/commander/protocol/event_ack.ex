defmodule GSMLG.Commander.Protocol.EventAck do
  @moduledoc "A cumulative acknowledgement for contiguous job event sequences."

  alias GSMLG.Commander.Protocol.Validation

  @enforce_keys [:protocol_version, :remote_execution_id, :highest_contiguous_sequence]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          protocol_version: pos_integer(),
          remote_execution_id: String.t(),
          highest_contiguous_sequence: non_neg_integer()
        }

  @fields ~w(type protocol_version remote_execution_id highest_contiguous_sequence)

  def decode(map) do
    with :ok <- Validation.fields(map, @fields),
         :ok <- Validation.protocol_version(map["protocol_version"]),
         :ok <- Validation.uuid(map["remote_execution_id"], "remote_execution_id"),
         :ok <-
           Validation.nonnegative_integer(
             map["highest_contiguous_sequence"],
             "highest_contiguous_sequence"
           ) do
      {:ok,
       %__MODULE__{
         protocol_version: map["protocol_version"],
         remote_execution_id: map["remote_execution_id"],
         highest_contiguous_sequence: map["highest_contiguous_sequence"]
       }}
    end
  end

  def encode(%__MODULE__{} = ack) do
    map = %{
      "type" => "event.ack",
      "protocol_version" => ack.protocol_version,
      "remote_execution_id" => ack.remote_execution_id,
      "highest_contiguous_sequence" => ack.highest_contiguous_sequence
    }

    with {:ok, _validated} <- decode(map), do: {:ok, map}
  end
end
