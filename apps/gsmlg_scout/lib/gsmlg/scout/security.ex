defmodule GSMLG.Scout.Security do
  @moduledoc """
  URL boundary checks for Scout fetch requests.
  """

  def validate_url(url, settings) when is_binary(url) do
    raw_uri = URI.parse(url)

    case URI.new(url) do
      {:ok, uri} ->
        with :ok <- validate_scheme(uri, settings),
             :ok <- validate_port(uri, raw_uri),
             :ok <- validate_host(uri, settings) do
          :ok
        end

      {:error, _reason} ->
        error(:invalid_url, "url is invalid", false)
    end
  end

  def validate_url(_url, _settings), do: error(:invalid_url, "url must be a string", false)

  defp validate_scheme(%URI{scheme: scheme}, settings) do
    allowed = settings["security"]["allowed_schemes"]

    if scheme in allowed do
      :ok
    else
      error(:unsupported_protocol, "only HTTP and HTTPS URLs are supported", false)
    end
  end

  defp validate_port(%URI{port: port}, %URI{authority: authority}) do
    cond do
      empty_port?(authority) ->
        error(:invalid_url, "url port is invalid", false)

      valid_port?(port) ->
        :ok

      true ->
        error(:invalid_url, "url port is invalid", false)
    end
  end

  defp valid_port?(port) when is_integer(port) and port in 1..65_535, do: true
  defp valid_port?(_port), do: false

  defp empty_port?(authority) when is_binary(authority), do: String.ends_with?(authority, ":")
  defp empty_port?(_authority), do: false

  defp validate_host(%URI{host: host}, settings) when is_binary(host) and host != "" do
    normalized = String.downcase(host)

    cond do
      normalized in ["localhost", "localhost.localdomain"] ->
        error(:blocked_target, "localhost targets are blocked", false)

      String.ends_with?(normalized, ".localhost") ->
        error(:blocked_target, "localhost targets are blocked", false)

      true ->
        validate_resolvable_host(normalized, settings)
    end
  end

  defp validate_host(_uri, _settings), do: error(:invalid_url, "url host is required", false)

  defp validate_resolvable_host(host, settings) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} ->
        validate_address(address, settings)

      {:error, :einval} ->
        validate_resolved_addresses(host, settings)
    end
  end

  defp validate_resolved_addresses(host, settings) do
    addresses =
      host
      |> resolve_addresses()
      |> Enum.flat_map(fn
        {:ok, resolved_addresses} -> resolved_addresses
        {:error, _reason} -> []
      end)

    cond do
      addresses == [] ->
        error(:unresolvable_host, "url host could not be resolved", true)

      Enum.any?(addresses, &blocked_address?(&1, settings)) ->
        error(:blocked_target, "private network targets are blocked", false)

      true ->
        :ok
    end
  end

  defp resolve_addresses(host) do
    resolver = Application.get_env(:gsmlg_scout, :dns_resolver, :inet)
    charlist_host = String.to_charlist(host)

    [
      safe_getaddrs(resolver, charlist_host, :inet),
      safe_getaddrs(resolver, charlist_host, :inet6)
    ]
  end

  defp safe_getaddrs(resolver, host, family) do
    case resolver.getaddrs(host, family) do
      {:ok, addresses} -> {:ok, addresses}
      {:error, reason} -> {:error, reason}
      error -> {:error, error}
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp validate_address(address, settings) do
    if blocked_address?(address, settings) do
      error(:blocked_target, "private network targets are blocked", false)
    else
      :ok
    end
  end

  defp blocked_address?({0, 0, 0, 0, 0, 65_535, _high, _low}, _settings), do: true

  defp blocked_address?(address, settings) do
    Enum.any?(settings["security"]["blocked_cidrs"], &cidr_contains?(&1, address))
  end

  defp cidr_contains?(cidr, address) do
    with [network, prefix] <- String.split(cidr, "/"),
         {prefix, ""} <- Integer.parse(prefix),
         {:ok, network_address} <- :inet.parse_address(String.to_charlist(network)),
         {network_int, bits} <- network_address |> normalize_address() |> ip_to_integer(),
         {address_int, ^bits} <- address |> normalize_address() |> ip_to_integer(),
         true <- prefix >= 0 and prefix <= bits do
      divisor = Integer.pow(2, bits - prefix)
      div(network_int, divisor) == div(address_int, divisor)
    else
      _ -> false
    end
  end

  defp normalize_address({0, 0, 0, 0, 0, 65_535, high, low}) do
    {
      div(high, 256),
      rem(high, 256),
      div(low, 256),
      rem(low, 256)
    }
  end

  defp normalize_address(address), do: address

  defp ip_to_integer({_, _, _, _} = address) do
    integer =
      address
      |> Tuple.to_list()
      |> Enum.reduce(0, fn part, acc -> acc * 256 + part end)

    {integer, 32}
  end

  defp ip_to_integer(address) when tuple_size(address) == 8 do
    integer =
      address
      |> Tuple.to_list()
      |> Enum.reduce(0, fn part, acc -> acc * 65_536 + part end)

    {integer, 128}
  end

  defp error(type, message, retryable) do
    {:error, %{type: to_string(type), message: message, retryable: retryable}}
  end
end
