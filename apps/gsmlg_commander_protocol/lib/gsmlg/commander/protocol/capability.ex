defmodule GSMLG.Commander.Protocol.Capability do
  @moduledoc "A versioned remote Commander capability descriptor."

  alias GSMLG.Commander.Protocol.Validation

  @enforce_keys [:id, :version, :backend, :operations, :limits, :workflows]
  defstruct [:id, :version, :backend, :operations, :limits, :workflows]

  @type t :: %__MODULE__{
          id: String.t(),
          version: pos_integer(),
          backend: String.t(),
          operations: [String.t()],
          limits: %{optional(String.t()) => non_neg_integer()},
          workflows: [String.t()]
        }

  @fields ~w(id version backend operations limits workflows)

  @spec decode(map()) :: {:ok, t()} | {:error, GSMLG.Commander.Protocol.Error.t()}
  def decode(map) when is_map(map) do
    with :ok <- Validation.fields(map, @fields),
         :ok <- Validation.capability(map["id"], map["version"]),
         :ok <- Validation.nonempty_string(map["backend"], "backend"),
         :ok <- Validation.operations(map["id"], map["operations"]),
         :ok <- Validation.limits(map["limits"]),
         :ok <- Validation.workflows(map["workflows"]) do
      {:ok,
       %__MODULE__{
         id: map["id"],
         version: map["version"],
         backend: map["backend"],
         operations: map["operations"],
         limits: map["limits"],
         workflows: map["workflows"]
       }}
    end
  end

  def decode(_capability) do
    Validation.invalid("invalid_capability_descriptor", %{})
  end

  @spec encode(t()) :: {:ok, map()} | {:error, GSMLG.Commander.Protocol.Error.t()}
  def encode(%__MODULE__{} = capability) do
    map = %{
      "id" => capability.id,
      "version" => capability.version,
      "backend" => capability.backend,
      "operations" => capability.operations,
      "limits" => capability.limits,
      "workflows" => capability.workflows
    }

    with {:ok, _validated} <- decode(map), do: {:ok, map}
  end

  def encode(_capability) do
    Validation.invalid("invalid_capability_descriptor", %{})
  end
end
