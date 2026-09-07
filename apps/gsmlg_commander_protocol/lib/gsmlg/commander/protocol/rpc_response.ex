defmodule GSMLG.Commander.Protocol.RPCResponse do
  @moduledoc "A terminal successful RPC response."

  alias GSMLG.Commander.Protocol.Validation

  @enforce_keys [:protocol_version, :request_id, :result]
  defstruct @enforce_keys

  @type t :: %__MODULE__{protocol_version: pos_integer(), request_id: String.t(), result: map()}

  @fields ~w(type protocol_version request_id result)

  def decode(map) do
    with :ok <- Validation.fields(map, @fields),
         :ok <- Validation.protocol_version(map["protocol_version"]),
         :ok <- Validation.uuid(map["request_id"], "request_id"),
         :ok <- Validation.wire_map(map["result"], "result") do
      {:ok,
       %__MODULE__{
         protocol_version: map["protocol_version"],
         request_id: map["request_id"],
         result: map["result"]
       }}
    end
  end

  def encode(%__MODULE__{} = response) do
    map = %{
      "type" => "rpc.response",
      "protocol_version" => response.protocol_version,
      "request_id" => response.request_id,
      "result" => response.result
    }

    with {:ok, _validated} <- decode(map), do: {:ok, map}
  end
end
