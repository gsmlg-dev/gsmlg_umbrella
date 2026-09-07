defmodule GSMLG.Commander.Protocol.RPCError do
  @moduledoc "A terminal failed RPC response safe for transport."

  alias GSMLG.Commander.Protocol.Validation

  @enforce_keys [
    :protocol_version,
    :request_id,
    :class,
    :code,
    :message,
    :retryable,
    :human_action,
    :details
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          protocol_version: pos_integer(),
          request_id: String.t(),
          class: String.t(),
          code: String.t(),
          message: String.t(),
          retryable: boolean(),
          human_action: String.t(),
          details: map()
        }

  @fields ~w(type protocol_version request_id class code message retryable human_action details)

  def decode(map) do
    with :ok <- Validation.fields(map, @fields),
         :ok <- Validation.protocol_version(map["protocol_version"]),
         :ok <- Validation.uuid(map["request_id"], "request_id"),
         :ok <- Validation.nonempty_string(map["class"], "class"),
         :ok <- Validation.nonempty_string(map["code"], "code"),
         :ok <- Validation.nonempty_string(map["message"], "message"),
         :ok <- Validation.boolean(map["retryable"], "retryable"),
         :ok <- Validation.nonempty_string(map["human_action"], "human_action"),
         :ok <- Validation.wire_map(map["details"], "details") do
      {:ok,
       %__MODULE__{
         protocol_version: map["protocol_version"],
         request_id: map["request_id"],
         class: map["class"],
         code: map["code"],
         message: map["message"],
         retryable: map["retryable"],
         human_action: map["human_action"],
         details: map["details"]
       }}
    end
  end

  def encode(%__MODULE__{} = rpc_error) do
    map = %{
      "type" => "rpc.error",
      "protocol_version" => rpc_error.protocol_version,
      "request_id" => rpc_error.request_id,
      "class" => rpc_error.class,
      "code" => rpc_error.code,
      "message" => rpc_error.message,
      "retryable" => rpc_error.retryable,
      "human_action" => rpc_error.human_action,
      "details" => rpc_error.details
    }

    with {:ok, _validated} <- decode(map), do: {:ok, map}
  end
end
