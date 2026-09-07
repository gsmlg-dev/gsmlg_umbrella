defmodule GSMLG.Commander.Protocol.RPCRequest do
  @moduledoc "A validated browser capability RPC request."

  alias GSMLG.Commander.Protocol.{BrowserControlPayload, Validation}

  @enforce_keys [
    :protocol_version,
    :request_id,
    :capability,
    :capability_version,
    :operation,
    :idempotency_key,
    :deadline_at,
    :payload
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          protocol_version: pos_integer(),
          request_id: String.t(),
          capability: String.t(),
          capability_version: pos_integer(),
          operation: String.t(),
          idempotency_key: String.t(),
          deadline_at: String.t(),
          payload: map()
        }

  @required ~w(type protocol_version request_id capability capability_version operation idempotency_key deadline_at payload)
  @max_encoded_bytes 256 * 1024

  @spec decode(map(), keyword()) :: {:ok, t()} | {:error, GSMLG.Commander.Protocol.Error.t()}
  def decode(map, opts \\ []) do
    with :ok <- validate(map, opts, true) do
      {:ok,
       %__MODULE__{
         protocol_version: map["protocol_version"],
         request_id: map["request_id"],
         capability: map["capability"],
         capability_version: map["capability_version"],
         operation: map["operation"],
         idempotency_key: map["idempotency_key"],
         deadline_at: map["deadline_at"],
         payload: map["payload"]
       }}
    end
  end

  @spec encode(t()) :: {:ok, map()} | {:error, GSMLG.Commander.Protocol.Error.t()}
  def encode(%__MODULE__{} = request) do
    map = %{
      "type" => "rpc.request",
      "protocol_version" => request.protocol_version,
      "request_id" => request.request_id,
      "capability" => request.capability,
      "capability_version" => request.capability_version,
      "operation" => request.operation,
      "idempotency_key" => request.idempotency_key,
      "deadline_at" => request.deadline_at,
      "payload" => request.payload
    }

    with :ok <- validate(map, [], false), do: {:ok, map}
  end

  defp validate(map, opts, check_expiration?) do
    with :ok <- Validation.fields(map, @required),
         :ok <- Validation.protocol_version(map["protocol_version"]),
         :ok <- Validation.uuid(map["request_id"], "request_id"),
         :ok <- Validation.capability(map["capability"], map["capability_version"]),
         :ok <- Validation.operation(map["capability"], map["operation"]),
         :ok <- Validation.nonempty_string(map["idempotency_key"], "idempotency_key"),
         :ok <- validate_deadline(map["deadline_at"], opts, check_expiration?),
         :ok <- Validation.wire_map(map["payload"], "payload"),
         :ok <- validate_size(map),
         :ok <-
           BrowserControlPayload.validate(
             map["capability"],
             map["capability_version"],
             map["operation"],
             map["payload"]
           ) do
      :ok
    end
  end

  defp validate_deadline(value, opts, true) do
    Validation.future_timestamp(value, "deadline_at", opts)
  end

  defp validate_deadline(value, _opts, false) do
    Validation.timestamp(value, "deadline_at")
  end

  defp validate_size(map) do
    with {:ok, encoded_size} <- Validation.encoded_size(map) do
      if encoded_size <= @max_encoded_bytes,
        do: :ok,
        else: Validation.invalid("message_too_large", %{"max_bytes" => @max_encoded_bytes})
    end
  end
end
