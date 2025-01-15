defmodule GSMLG.Whois.Server do
  @moduledoc """
  Define whois server address.
  Find whois server of Domain, IP or AS.
  """
  defstruct [:host]

  @type t :: %__MODULE__{host: binary()}

  def root() do
    %GSMLG.Whois.Server{host: "whois.iana.org"}
  end

  @spec for_domain(binary()) :: {:ok, t}
  def for_domain(_) do
    {:ok, root()}
  end

  @spec for_ip(binary()) :: {:ok, t}
  def for_ip(_) do
    {:ok, root()}
  end

  @spec for_asn(binary() | integer()) :: {:ok, t}
  def for_asn(_) do
    {:ok, root()}
  end
end
