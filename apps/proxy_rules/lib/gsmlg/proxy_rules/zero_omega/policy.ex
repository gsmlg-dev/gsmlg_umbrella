defmodule GSMLG.ProxyRules.ZeroOmega.Policy do
  @moduledoc """
  An immutable, normalized policy consumed by ZeroOmega exporters.
  """

  alias GSMLG.ProxyRules.ZeroOmega.Rule

  @enforce_keys [:revision, :default_action, :rules]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          revision: String.t(),
          default_action: :default,
          rules: [Rule.t()]
        }
end
