defmodule GSMLG.Commander.Protocol.CapabilitiesUpdate do
  @moduledoc "Runtime replacement snapshot for a negotiated connection's capabilities."

  alias GSMLG.Commander.Protocol.Capability
  alias GSMLG.Commander.Protocol.Validation

  @enforce_keys [:protocol_version, :capabilities]
  defstruct [:protocol_version, :capabilities]

  @type t :: %__MODULE__{protocol_version: pos_integer(), capabilities: [Capability.t()]}

  @fields ~w(type protocol_version capabilities)

  @spec decode(map()) :: {:ok, t()} | {:error, GSMLG.Commander.Protocol.Error.t()}
  def decode(map) do
    with :ok <- Validation.fields(map, @fields),
         :ok <- Validation.protocol_version(map["protocol_version"]),
         {:ok, capabilities} <- decode_capabilities(map["capabilities"]) do
      {:ok, %__MODULE__{protocol_version: map["protocol_version"], capabilities: capabilities}}
    end
  end

  @spec encode(t()) :: {:ok, map()} | {:error, GSMLG.Commander.Protocol.Error.t()}
  def encode(%__MODULE__{} = update) do
    with {:ok, capabilities} <- encode_capabilities(update.capabilities) do
      map = %{
        "type" => "capabilities.update",
        "protocol_version" => update.protocol_version,
        "capabilities" => capabilities
      }

      with {:ok, _validated} <- decode(map), do: {:ok, map}
    end
  end

  defp decode_capabilities(capabilities) when is_list(capabilities) do
    reduce(capabilities, &Capability.decode/1)
  end

  defp decode_capabilities(_capabilities) do
    Validation.invalid("invalid_list", %{"field" => "capabilities"})
  end

  defp encode_capabilities(capabilities) when is_list(capabilities) do
    reduce(capabilities, &Capability.encode/1)
  end

  defp encode_capabilities(_capabilities) do
    Validation.invalid("invalid_list", %{"field" => "capabilities"})
  end

  defp reduce(values, function) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case function.(value) do
        {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _error} = error -> error
    end
  end
end
