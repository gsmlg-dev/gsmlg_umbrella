defmodule GSMLG.Commander.Protocol.RPCAccepted do
  @moduledoc "Acceptance of a long-running RPC operation."

  alias GSMLG.Commander.Protocol.Validation

  @enforce_keys [:protocol_version, :request_id, :remote_execution_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          protocol_version: pos_integer(),
          request_id: String.t(),
          remote_execution_id: String.t()
        }

  @fields ~w(type protocol_version request_id remote_execution_id)

  def decode(map) do
    with :ok <- Validation.fields(map, @fields),
         :ok <- Validation.protocol_version(map["protocol_version"]),
         :ok <- Validation.uuid(map["request_id"], "request_id"),
         :ok <- Validation.uuid(map["remote_execution_id"], "remote_execution_id") do
      {:ok,
       %__MODULE__{
         protocol_version: map["protocol_version"],
         request_id: map["request_id"],
         remote_execution_id: map["remote_execution_id"]
       }}
    end
  end

  def encode(%__MODULE__{} = accepted) do
    map = %{
      "type" => "rpc.accepted",
      "protocol_version" => accepted.protocol_version,
      "request_id" => accepted.request_id,
      "remote_execution_id" => accepted.remote_execution_id
    }

    with {:ok, _validated} <- decode(map), do: {:ok, map}
  end
end
