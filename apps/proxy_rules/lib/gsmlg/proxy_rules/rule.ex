defmodule GSMLG.ProxyRules.Rule do
  @moduledoc """
  A typed proxy-routing rule produced by a source parser.
  """

  alias GSMLG.ProxyRules.Domain

  @enforce_keys [:domain, :action, :source, :location]
  defstruct [:domain, :action, :source, :location, match: :suffix]

  @type action :: :proxy | :direct
  @type match :: :suffix
  @type source :: :gfwlist | :local_proxy | :local_direct
  @type location :: pos_integer()

  @type t :: %__MODULE__{
          domain: Domain.t(),
          action: action(),
          source: source(),
          location: location(),
          match: match()
        }
end
