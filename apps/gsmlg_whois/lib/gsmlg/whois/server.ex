defmodule GSMLG.Whois.Server do
  @moduledoc """
  Define whois server address.
  Find whois server of Domain, IP or AS.
  """
  defstruct [:host]

  @type t :: %__MODULE__{host: String.t()}

  def root() do
    %GSMLG.Whois.Server{host: "whois.iana.org"}
  end

  @spec for_domain(String.t()) :: {:ok, t}
  def for_domain(_) do
    {:ok, %GSMLG.Whois.Server{host: "whois.iana.org"}}
  end

  @spec for_ip(String.t()) :: {:ok, t}
  def for_ip(_) do
    {:ok, %GSMLG.Whois.Server{host: "whois.iana.org"}}
  end

  @spec for_asn(String.t() | Integer.t()) :: {:ok, t}
  def for_asn(_) do
    {:ok, %GSMLG.Whois.Server{host: "whois.iana.org"}}
  end
end
