defmodule GSMLG.ProxyRules.Diagnostic do
  @moduledoc """
  A bounded parser diagnostic suitable for reporting malformed input and
  source-level failures.
  """

  @enforce_keys [:kind, :source, :location, :reason]
  defstruct [:kind, :source, :location, :reason, :sample]

  @type kind :: :invalid | :unsupported | :systemic
  @type source :: atom()
  @type location :: pos_integer() | :system
  @type reason :: atom()

  @type t :: %__MODULE__{
          kind: kind(),
          source: source(),
          location: location(),
          reason: reason(),
          sample: String.t() | nil
        }
end
