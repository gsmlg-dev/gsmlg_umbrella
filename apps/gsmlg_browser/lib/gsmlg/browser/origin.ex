defmodule GSMLG.Browser.Origin do
  @moduledoc false

  @spec canonical?(term()) :: boolean()
  def canonical?(value) when is_binary(value) and byte_size(value) in 1..2_048 do
    String.valid?(value) and canonical_uri?(value)
  end

  def canonical?(_value), do: false

  defp canonical_uri?(value) do
    case URI.parse(value) do
      %URI{
        scheme: "https",
        host: host,
        port: port,
        userinfo: nil,
        path: path,
        query: nil,
        fragment: nil
      } = uri
      when is_binary(host) and host != "" and path in [nil, ""] and
             (is_nil(port) or port in 1..65_535) ->
        not local_hostname?(host) and not private_literal?(host) and canonical(uri) == value

      _invalid ->
        false
    end
  end

  defp canonical(uri) do
    host = String.downcase(uri.host)
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host
    port = if uri.port in [nil, 443], do: "", else: ":#{uri.port}"
    "https://#{host}#{port}"
  end

  defp local_hostname?(host) do
    host = String.downcase(host)

    host == "localhost" or String.ends_with?(host, ".localhost") or
      String.ends_with?(host, ".local") or String.ends_with?(host, ".internal")
  end

  defp private_literal?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> private_address?(address)
      {:error, _reason} -> false
    end
  end

  defp private_address?({10, _, _, _}), do: true
  defp private_address?({127, _, _, _}), do: true
  defp private_address?({169, 254, _, _}), do: true
  defp private_address?({172, second, _, _}) when second in 16..31, do: true
  defp private_address?({192, 0, 0, _}), do: true
  defp private_address?({192, 0, 2, _}), do: true
  defp private_address?({192, 168, _, _}), do: true
  defp private_address?({0, _, _, _}), do: true
  defp private_address?({100, second, _, _}) when second in 64..127, do: true
  defp private_address?({198, third, _, _}) when third in [18, 19], do: true
  defp private_address?({198, 51, 100, _}), do: true
  defp private_address?({203, 0, 113, _}), do: true
  defp private_address?({first, _, _, _}) when first >= 224, do: true
  defp private_address?({0, 0, 0, 0, 0, 0, 0, _}), do: true
  defp private_address?({first, _, _, _, _, _, _, _}) when first in 0xFC00..0xFDFF, do: true
  defp private_address?({first, _, _, _, _, _, _, _}) when first in 0xFE80..0xFEFF, do: true
  defp private_address?({first, _, _, _, _, _, _, _}) when first in 0xFF00..0xFFFF, do: true
  defp private_address?({0x2001, 0xDB8, _, _, _, _, _, _}), do: true
  defp private_address?({0x2001, 0x0002, _, _, _, _, _, _}), do: true
  defp private_address?({0x0100, 0, 0, 0, _, _, _, _}), do: true

  defp private_address?({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: private_address?({div(high, 256), rem(high, 256), div(low, 256), rem(low, 256)})

  defp private_address?(_address), do: false
end
