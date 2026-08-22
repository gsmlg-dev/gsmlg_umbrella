defmodule GSMLG.ProxyRules.ZeroOmega.Rule do
  @moduledoc """
  One canonical ZeroOmega export rule.
  """

  @enforce_keys [:id, :priority, :enabled, :condition, :action, :input_order]
  defstruct @enforce_keys ++ [note: nil]

  @type action :: :match | :default | {:profile, String.t()}
  @type condition ::
          {:domain_suffix, String.t()}
          | {:host_exact, String.t()}
          | {:host_glob, String.t()}
          | {:url_prefix, String.t()}
          | {:url_glob, String.t()}
          | {:url_regex, String.t()}
          | {:cidr, String.t()}
          | {:keyword, String.t()}

  @type t :: %__MODULE__{
          id: String.t(),
          priority: non_neg_integer(),
          enabled: boolean(),
          condition: condition(),
          action: action(),
          note: String.t() | nil,
          input_order: non_neg_integer()
        }
end
