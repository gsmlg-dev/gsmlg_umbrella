defmodule GSMLG.Commander.Protocol.Error do
  @moduledoc "Safe validation error returned by the Commander capability protocol."

  @enforce_keys [:class, :code, :details]
  defstruct [:class, :code, :details]

  @type t :: %__MODULE__{
          class: String.t(),
          code: String.t(),
          details: %{optional(String.t()) => term()}
        }

  @spec new(String.t(), String.t(), map()) :: t()
  def new(class, code, details \\ %{}) do
    %__MODULE__{class: class, code: code, details: details}
  end
end
