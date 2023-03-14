defmodule GSMLG.Whois.Server do
  defstruct [:host]

  @type t :: %__MODULE__{host: String.t()}

  import GSMLG.Whois.Helper

  define_from_file(:asn16)
  define_from_file(:asn32)
  define_from_file(:ipv4)
  define_from_file(:ipv6)
  define_from_file(:tld)

  @spec for_domain(String.t()) :: {:ok, t} | :error
  def for_domain(domain) do
    [_, name] = String.split(domain, ".", parts: 2)
    Map.fetch(tld(), name)
  end

  @spec for_ipv4(String.t()) :: {:ok, t} | :error
  def for_ipv4(addr) do
    ip = InetCidr.parse_address!(addr)

    n =
      ipv4()
      |> Map.keys()
      |> Enum.find(fn net ->
        cidr = InetCidr.parse(net, true)
        InetCidr.contains?(cidr, ip)
      end)

    case n do
      nil -> :error
      n -> {:ok, Map.get(ipv4(), n)}
    end
  end

  @spec for_ipv6(String.t()) :: {:ok, t} | :error
  def for_ipv6(addr) do
    ip = InetCidr.parse_address!(addr)

    n =
      ipv6()
      |> Map.keys()
      |> Enum.find(fn net ->
        cidr = InetCidr.parse(net, true)
        InetCidr.contains?(cidr, ip)
      end)

    case n do
      nil -> :error
      n -> {:ok, Map.get(ipv6(), n)}
    end
  end

  @spec for_ip(String.t()) :: {:ok, t} | :error
  def for_ip(addr) do
    ip = InetCidr.parse_address!(addr)

    cond do
      InetCidr.v4?(ip) -> for_ipv4(addr)
      InetCidr.v6?(ip) -> for_ipv6(addr)
      true -> :error
    end
  end

  @spec for_asn16(String.t() | Integer.t()) :: {:ok, t} | :error
  def for_asn16(as) when is_binary(as), do: String.to_integer(as) |> for_asn16()

  def for_asn16(as) do
    n =
      asn16()
      |> Map.keys()
      |> Enum.find(fn asn ->
        case String.split(asn) do
          [s, e] ->
            s = String.to_integer(s)
            e = String.to_integer(e)
            as >= s and as <= e

          [n] ->
            String.to_integer(n) == as
        end
      end)

    case n do
      nil -> :error
      n -> {:ok, Map.get(asn16(), n)}
    end
  end

  def for_asn32(as) when is_binary(as), do: String.to_integer(as) |> for_asn32()

  def for_asn32(as) when is_integer(as) do
    n =
      asn32()
      |> Map.keys()
      |> Enum.find(fn asn ->
        case String.split(asn) do
          [s, e] ->
            s = String.to_integer(s)
            e = String.to_integer(e)
            as >= s and as <= e

          [n] ->
            String.to_integer(n) == as
        end
      end)

    case n do
      nil -> :error
      n -> {:ok, Map.get(asn32(), n)}
    end
  end

  @spec for_asn32(String.t() | Integer.t()) :: {:ok, t} | :error
  def for_asn(as) when is_binary(as), do: String.to_integer(as) |> for_asn()

  def for_asn(as) when is_integer(as) do
    cond do
      as > 0 and as < 2 ** 16 -> for_asn16(as)
      as >= 2 ** 16 and as < 2 ** 32 -> for_asn32(as)
      true -> :error
    end
  end
end
