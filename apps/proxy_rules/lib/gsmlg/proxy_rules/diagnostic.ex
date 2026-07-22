defmodule GSMLG.ProxyRules.Diagnostic do
  @moduledoc """
  A bounded parser diagnostic suitable for reporting malformed input and
  source-level failures.
  """

  @enforce_keys [:kind, :source, :location, :reason]
  defstruct [:kind, :source, :location, :reason, :sample]

  @type kind :: :invalid | :unsupported | :systemic
  @type source :: GSMLG.ProxyRules.Rule.source()
  @type location :: pos_integer() | :system
  @type reason ::
          GSMLG.ProxyRules.Domain.error_reason()
          | :invalid_base64
          | :invalid_utf8
          | :path_specific
          | :regular_expression
          | :modifier
          | :wildcard
          | :ambiguous_rule
          | :systemic_failure

  @reasons [
    :invalid_value,
    :empty_domain,
    :invalid_url,
    :unsupported_scheme,
    :invalid_idna,
    :ip_literal,
    :domain_too_long,
    :empty_label,
    :label_too_long,
    :invalid_label,
    :invalid_base64,
    :invalid_utf8,
    :path_specific,
    :regular_expression,
    :modifier,
    :wildcard,
    :ambiguous_rule,
    :systemic_failure
  ]

  @type t :: %__MODULE__{
          kind: kind(),
          source: source(),
          location: location(),
          reason: reason(),
          sample: String.t() | nil
        }

  @spec valid_reason?(term()) :: boolean()
  def valid_reason?(reason), do: reason in @reasons
end
