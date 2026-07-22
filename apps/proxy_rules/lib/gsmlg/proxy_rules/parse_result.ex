defmodule GSMLG.ProxyRules.ParseResult do
  @moduledoc """
  The accepted rules, aggregate counts, and bounded diagnostics returned by a
  parser.
  """

  alias GSMLG.ProxyRules.{Diagnostic, Rule}

  defstruct rules: [], counts: %{accepted: 0, invalid: 0, unsupported: 0}, diagnostics: []

  @type counts :: %{
          required(:accepted) => non_neg_integer(),
          required(:invalid) => non_neg_integer(),
          required(:unsupported) => non_neg_integer()
        }

  @type t :: %__MODULE__{
          rules: [Rule.t()],
          counts: counts(),
          diagnostics: [Diagnostic.t()]
        }
end
