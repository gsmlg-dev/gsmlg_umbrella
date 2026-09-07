defmodule GSMLG.BrowserAgent.OriginPolicy do
  @moduledoc "Default-deny navigation and redirect policy for remote browser sessions."

  @enforce_keys [:allowed_origins, :allowed_schemes]
  defstruct [:allowed_origins, :allowed_schemes]

  @type t :: %__MODULE__{
          allowed_origins: MapSet.t(String.t()),
          allowed_schemes: MapSet.t(String.t())
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_origin_policy}
  def new(opts) do
    origins = Keyword.get(opts, :allowed_origins, [])
    schemes = Keyword.get(opts, :allowed_schemes, ["https"])

    with true <- is_list(origins) and origins != [],
         true <- is_list(schemes) and schemes != [],
         true <- Enum.all?(schemes, &(&1 in ["https"])),
         {:ok, normalized} <- normalize_origins(origins, schemes) do
      {:ok,
       %__MODULE__{
         allowed_origins: MapSet.new(normalized),
         allowed_schemes: MapSet.new(schemes)
       }}
    else
      _invalid -> {:error, :invalid_origin_policy}
    end
  end

  @spec authorize(t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :navigation_not_allowed}
  def authorize(%__MODULE__{} = policy, url, opts \\ []) do
    with {:ok, uri} <- parse_absolute_url(url),
         true <- MapSet.member?(policy.allowed_schemes, uri.scheme),
         {:ok, origin} <- origin_uri(uri),
         true <- MapSet.member?(policy.allowed_origins, origin),
         false <- local_hostname?(uri.host),
         false <- private_literal?(uri.host),
         {:ok, addresses} <- resolve(uri.host, opts),
         false <- Enum.any?(addresses, &private_address?/1) do
      {:ok, origin}
    else
      _not_allowed -> {:error, :navigation_not_allowed}
    end
  end

  @spec authorize_redirect(t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :navigation_not_allowed}
  def authorize_redirect(%__MODULE__{} = policy, _from_url, to_url, opts \\ []) do
    authorize(policy, to_url, opts)
  end

  @spec origin(String.t()) :: {:ok, String.t()} | {:error, :invalid_url}
  def origin(url) when is_binary(url) do
    with {:ok, uri} <- parse_absolute_url(url), do: origin_uri(uri)
  end

  def origin(_url), do: {:error, :invalid_url}

  @doc "Returns whether a CDP-reported socket peer is a globally routable IP address."
  @spec global_address?(String.t() | :inet.ip_address()) :: boolean()
  def global_address?(address) when is_binary(address) do
    if String.valid?(address) do
      case :inet.parse_address(String.to_charlist(address)) do
        {:ok, parsed} -> global_address?(parsed)
        {:error, _reason} -> false
      end
    else
      false
    end
  end

  def global_address?(address) when is_tuple(address),
    do: valid_address?(address) and not private_address?(address)

  def global_address?(_address), do: false

  defp normalize_origins(origins, schemes) do
    Enum.reduce_while(origins, {:ok, []}, fn value, {:ok, normalized} ->
      with {:ok, uri} <- parse_absolute_url(value),
           true <- uri.scheme in schemes,
           true <- uri.path in [nil, "", "/"],
           true <- is_nil(uri.query) and is_nil(uri.fragment) and is_nil(uri.userinfo),
           false <- local_hostname?(uri.host),
           false <- private_literal?(uri.host),
           {:ok, item} <- origin_uri(uri) do
        {:cont, {:ok, [item | normalized]}}
      else
        _invalid -> {:halt, {:error, :invalid_origin_policy}}
      end
    end)
  end

  defp parse_absolute_url(url) when is_binary(url) and byte_size(url) in 1..2_048 do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil} = uri
      when is_binary(scheme) and is_binary(host) and host != "" ->
        {:ok, %{uri | host: String.downcase(host), scheme: String.downcase(scheme)}}

      _invalid ->
        {:error, :invalid_url}
    end
  end

  defp parse_absolute_url(_url), do: {:error, :invalid_url}

  defp origin_uri(%URI{} = uri) do
    default_port = URI.default_port(uri.scheme)

    authority =
      case uri.port do
        nil -> format_host(uri.host)
        ^default_port -> format_host(uri.host)
        port -> "#{format_host(uri.host)}:#{port}"
      end

    {:ok, "#{uri.scheme}://#{authority}"}
  end

  defp format_host(host) do
    if String.contains?(host, ":"), do: "[#{host}]", else: host
  end

  defp resolve(host, opts) do
    resolver = Keyword.get(opts, :resolver, &system_resolve/1)

    case resolver.(host) do
      {:ok, addresses} when is_list(addresses) and addresses != [] ->
        if Enum.all?(addresses, &valid_address?/1) do
          {:ok, addresses}
        else
          {:error, :resolution_failed}
        end

      _failed ->
        {:error, :resolution_failed}
    end
  end

  defp valid_address?(address) when is_tuple(address) and tuple_size(address) == 4 do
    address
    |> Tuple.to_list()
    |> Enum.all?(&(is_integer(&1) and &1 in 0..255))
  end

  defp valid_address?(address) when is_tuple(address) and tuple_size(address) == 8 do
    address
    |> Tuple.to_list()
    |> Enum.all?(&(is_integer(&1) and &1 in 0..65_535))
  end

  defp valid_address?(_address), do: false

  defp system_resolve(host) do
    char_host = String.to_charlist(host)

    addresses =
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case :inet.getaddrs(char_host, family) do
          {:ok, items} -> items
          {:error, _reason} -> []
        end
      end)
      |> Enum.uniq()

    if addresses == [], do: {:error, :nxdomain}, else: {:ok, addresses}
  end

  defp local_hostname?(host) do
    host = String.downcase(host)

    host == "localhost" or String.ends_with?(host, ".localhost") or
      String.ends_with?(host, ".local") or String.ends_with?(host, ".internal")
  end

  defp private_literal?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> private_address?(address)
      {:error, :einval} -> false
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
  defp private_address?({first, _, _, _}) when first in 224..239, do: true
  defp private_address?({first, _, _, _}) when first >= 240, do: true
  defp private_address?({0, 0, 0, 0, 0, 0, 0, _}), do: true
  defp private_address?({first, _, _, _, _, _, _, _}) when first in 0xFC00..0xFDFF, do: true
  defp private_address?({first, _, _, _, _, _, _, _}) when first in 0xFE80..0xFEBF, do: true
  defp private_address?({first, _, _, _, _, _, _, _}) when first in 0xFEC0..0xFEFF, do: true
  defp private_address?({first, _, _, _, _, _, _, _}) when first in 0xFF00..0xFFFF, do: true
  defp private_address?({0x2001, 0xDB8, _, _, _, _, _, _}), do: true
  defp private_address?({0x2001, 0x0002, _, _, _, _, _, _}), do: true
  defp private_address?({0x0100, 0, 0, 0, _, _, _, _}), do: true

  defp private_address?({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: private_address?({div(high, 256), rem(high, 256), div(low, 256), rem(low, 256)})

  defp private_address?(_address), do: false
end
