defmodule GSMLG.AdminWeb.NoteSyncSerializer do
  @moduledoc "Phoenix V2 JSON with a complete-message cap and strict sync join references."
  @behaviour Phoenix.Socket.Serializer
  alias Phoenix.Socket.V2.JSONSerializer
  @impl true
  defdelegate fastlane!(message), to: JSONSerializer
  @impl true
  defdelegate encode!(message), to: JSONSerializer

  @impl true
  def decode!(raw, options) do
    bytes = IO.iodata_to_binary(raw)

    with true <- options[:opcode] == :text and byte_size(bytes) <= 131_072,
         [join_ref, ref, topic, event, payload] <- Jason.decode!(bytes),
         true <- (is_nil(join_ref) or is_binary(join_ref)) and (is_nil(ref) or is_binary(ref)),
         true <- is_binary(topic) and is_binary(event) and is_map(payload),
         true <- topic != "note_sync:v1" or is_binary(join_ref) do
      JSONSerializer.decode!(bytes, options)
    else
      _ -> raise ArgumentError, "invalid note sync frame"
    end
  end
end
