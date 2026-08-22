defmodule GSMLG.ProxyRules.ZeroOmega.Diagnostic do
  @moduledoc """
  A bounded structured error produced by ZeroOmega normalization or rendering.
  """

  @enforce_keys [:severity, :code, :message]
  defstruct @enforce_keys ++ [rule_id: nil, field: nil]

  @type code ::
          :invalid_domain
          | :invalid_url
          | :invalid_regex
          | :invalid_cidr
          | :invalid_rule
          | :line_injection
          | :unsupported_condition
          | :unsupported_action
          | :ambiguous_profile_name
          | :conflicting_rule
          | :missing_default_profile
          | :invalid_proxy

  @type t :: %__MODULE__{
          severity: :error,
          code: code(),
          rule_id: String.t() | nil,
          field: atom() | nil,
          message: String.t()
        }

  @spec error(code(), String.t(), keyword()) :: t()
  def error(code, message, options \\ []) do
    %__MODULE__{
      severity: :error,
      code: code,
      message: message,
      rule_id: Keyword.get(options, :rule_id),
      field: Keyword.get(options, :field)
    }
  end
end
