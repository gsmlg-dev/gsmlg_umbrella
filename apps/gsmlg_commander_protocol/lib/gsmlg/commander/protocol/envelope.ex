defmodule GSMLG.Commander.Protocol.Envelope do
  @moduledoc """
  Strict codec facade for the Commander capability protocol.

  Public wire envelopes are maps with string keys. Decoding never creates atoms
  from input and all expected validation failures are returned as safe data.
  """

  alias GSMLG.Commander.Protocol.Capability
  alias GSMLG.Commander.Protocol.CapabilitiesUpdate
  alias GSMLG.Commander.Protocol.ArtifactManifest
  alias GSMLG.Commander.Protocol.Constants
  alias GSMLG.Commander.Protocol.EventAck
  alias GSMLG.Commander.Protocol.JobEvent
  alias GSMLG.Commander.Protocol.RPCAccepted
  alias GSMLG.Commander.Protocol.RPCError
  alias GSMLG.Commander.Protocol.RPCRequest
  alias GSMLG.Commander.Protocol.RPCResponse
  alias GSMLG.Commander.Protocol.Validation
  alias GSMLG.Commander.Protocol.VersionNegotiation

  @max_encoded_bytes 256 * 1024

  @type envelope ::
          VersionNegotiation.t()
          | CapabilitiesUpdate.t()
          | Capability.t()
          | RPCRequest.t()
          | RPCAccepted.t()
          | RPCResponse.t()
          | RPCError.t()
          | JobEvent.t()
          | EventAck.t()
          | ArtifactManifest.t()

  @spec protocol_version() :: 1
  defdelegate protocol_version(), to: Constants

  @spec browser_control_version() :: 1
  defdelegate browser_control_version(), to: Constants

  @spec browser_control_operations() :: [String.t()]
  defdelegate browser_control_operations(), to: Constants

  @spec decode(map()) :: {:ok, envelope()} | {:error, GSMLG.Commander.Protocol.Error.t()}
  def decode(wire), do: decode(wire, [])

  @spec decode(map(), keyword()) ::
          {:ok, envelope()} | {:error, GSMLG.Commander.Protocol.Error.t()}
  def decode(wire, opts) when is_map(wire) and is_list(opts) do
    with :ok <- Validation.wire_map(wire, "envelope"),
         :ok <- validate_size(wire),
         {:ok, type} <- message_type(wire) do
      decode_type(type, wire, opts)
    end
  end

  def decode(_wire, _opts) do
    Validation.error("protocol", "invalid_envelope", %{"expected" => "map"})
  end

  @spec encode(envelope()) :: {:ok, map()} | {:error, GSMLG.Commander.Protocol.Error.t()}
  def encode(envelope) do
    with {:ok, wire} <- encode_type(envelope),
         :ok <- Validation.wire_map(wire, "envelope"),
         :ok <- validate_size(wire) do
      {:ok, wire}
    end
  end

  defp message_type(%{"type" => type}) when is_binary(type), do: {:ok, type}

  defp message_type(%{"type" => _type}),
    do: Validation.invalid("invalid_string", %{"field" => "type"})

  defp message_type(_wire), do: Validation.invalid("missing_field", %{"fields" => ["type"]})

  defp decode_type("version.negotiation", wire, _opts), do: VersionNegotiation.decode(wire)
  defp decode_type("capabilities.update", wire, _opts), do: CapabilitiesUpdate.decode(wire)

  defp decode_type("capability.descriptor", wire, _opts) do
    with :ok <- Validation.fields(wire, ["type", "protocol_version"] ++ descriptor_fields()),
         :ok <- Validation.protocol_version(wire["protocol_version"]),
         descriptor = Map.drop(wire, ["type", "protocol_version"]),
         {:ok, capability} <- Capability.decode(descriptor) do
      {:ok, capability}
    end
  end

  defp decode_type("rpc.request", wire, opts), do: RPCRequest.decode(wire, opts)
  defp decode_type("rpc.accepted", wire, _opts), do: RPCAccepted.decode(wire)
  defp decode_type("rpc.response", wire, _opts), do: RPCResponse.decode(wire)
  defp decode_type("rpc.error", wire, _opts), do: RPCError.decode(wire)
  defp decode_type("job.event", wire, _opts), do: JobEvent.decode(wire)
  defp decode_type("event.ack", wire, _opts), do: EventAck.decode(wire)
  defp decode_type("artifact.manifest", wire, _opts), do: ArtifactManifest.decode(wire)

  defp decode_type(_unknown, _wire, _opts) do
    Validation.error("protocol", "unknown_message_type", %{
      "supported" => [
        "version.negotiation",
        "capabilities.update",
        "capability.descriptor",
        "rpc.request",
        "rpc.accepted",
        "rpc.response",
        "rpc.error",
        "job.event",
        "event.ack",
        "artifact.manifest"
      ]
    })
  end

  defp encode_type(%VersionNegotiation{} = negotiation),
    do: VersionNegotiation.encode(negotiation)

  defp encode_type(%CapabilitiesUpdate{} = update), do: CapabilitiesUpdate.encode(update)

  defp encode_type(%Capability{} = capability) do
    with {:ok, descriptor} <- Capability.encode(capability) do
      {:ok,
       Map.merge(descriptor, %{
         "type" => "capability.descriptor",
         "protocol_version" => Constants.protocol_version()
       })}
    end
  end

  defp encode_type(%RPCRequest{} = request), do: RPCRequest.encode(request)
  defp encode_type(%RPCAccepted{} = accepted), do: RPCAccepted.encode(accepted)
  defp encode_type(%RPCResponse{} = response), do: RPCResponse.encode(response)
  defp encode_type(%RPCError{} = rpc_error), do: RPCError.encode(rpc_error)
  defp encode_type(%JobEvent{} = event), do: JobEvent.encode(event)
  defp encode_type(%EventAck{} = ack), do: EventAck.encode(ack)
  defp encode_type(%ArtifactManifest{} = manifest), do: ArtifactManifest.encode(manifest)

  defp encode_type(_unsupported) do
    Validation.error("protocol", "unsupported_struct", %{})
  end

  defp validate_size(wire) do
    case Validation.encoded_size(wire) do
      {:ok, size} when size <= @max_encoded_bytes ->
        :ok

      {:ok, size} ->
        Validation.error("size", "message_too_large", %{
          "max_bytes" => @max_encoded_bytes,
          "actual_bytes" => size
        })

      {:error, _error} = error ->
        error
    end
  end

  defp descriptor_fields, do: ~w(id version backend operations limits workflows)
end
