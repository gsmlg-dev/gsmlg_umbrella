defmodule GSMLG.ProxyRules.Domain do
  @moduledoc """
  A validated DNS domain in canonical ASCII form.

  Domains are normalized from bare host names or HTTP(S) URLs and retain
  reversed labels for efficient suffix matching.
  """

  @enforce_keys [:name, :reversed_labels]
  defstruct [:name, :reversed_labels]

  @type t :: %__MODULE__{name: String.t(), reversed_labels: [String.t()]}
  @type error_reason ::
          :invalid_value
          | :empty_domain
          | :invalid_url
          | :unsupported_scheme
          | :invalid_idna
          | :ip_literal
          | :domain_too_long
          | :empty_label
          | :label_too_long
          | :invalid_label

  @doc """
  Normalizes a bare domain or the host of an HTTP(S) URL.

  Unicode names are converted to IDNA ASCII. Invalid domains and unsupported
  URL forms return a bounded reason atom.
  """
  @spec normalize(String.t()) :: {:ok, t()} | {:error, error_reason()}
  def normalize(value) when is_binary(value) do
    with {:ok, host} <- extract_host(String.trim(value)),
         host <- remove_optional_suffix_dots(host),
         :ok <- validate_source_labels(host),
         {:ok, ascii} <- to_ascii(host),
         ascii <- String.downcase(ascii),
         :ok <- validate_ascii(ascii) do
      {:ok,
       %__MODULE__{
         name: ascii,
         reversed_labels: ascii |> String.split(".") |> Enum.reverse()
       }}
    end
  end

  def normalize(_value), do: {:error, :invalid_value}

  defp extract_host(""), do: {:error, :empty_domain}

  defp extract_host(value) do
    value
    |> URI.parse()
    |> host_from_uri(value)
  rescue
    ArgumentError -> {:error, :invalid_url}
  end

  defp host_from_uri(
         %URI{scheme: nil, authority: nil, path: path, query: nil, fragment: nil},
         value
       )
       when path == value,
       do: {:ok, value}

  defp host_from_uri(
         %URI{
           scheme: scheme,
           authority: authority,
           host: host,
           userinfo: nil,
           query: nil,
           fragment: nil,
           path: path
         },
         _value
       )
       when scheme in ["http", "https"] and is_binary(host) and host != "" and
              path in [nil, "", "/"],
       do: if(valid_authority?(authority, host), do: {:ok, host}, else: {:error, :invalid_url})

  defp host_from_uri(%URI{scheme: scheme}, _value) when scheme in ["http", "https"],
    do: {:error, :invalid_url}

  defp host_from_uri(%URI{scheme: scheme}, _value) when is_binary(scheme),
    do: {:error, :unsupported_scheme}

  defp host_from_uri(_uri, _value), do: {:error, :invalid_url}

  defp valid_authority?(authority, host) do
    bare_authority = if String.contains?(host, ":"), do: "[#{host}]", else: host

    authority == bare_authority or valid_port_authority?(authority, bare_authority)
  end

  defp valid_port_authority?(authority, bare_authority) do
    case Regex.run(~r/\A#{Regex.escape(bare_authority)}:(\d+)\z/, authority,
           capture: :all_but_first
         ) do
      [port] -> String.to_integer(port) <= 65_535
      nil -> false
    end
  end

  defp remove_optional_suffix_dots(host) do
    host
    |> remove_leading_dot()
    |> remove_trailing_dot()
  end

  defp remove_leading_dot(<<".", rest::binary>>), do: rest
  defp remove_leading_dot(host), do: host

  defp remove_trailing_dot(host) do
    if String.ends_with?(host, ".") do
      binary_part(host, 0, byte_size(host) - 1)
    else
      host
    end
  end

  defp validate_source_labels(host) do
    if Enum.any?(String.split(host, ".", trim: false), &(&1 == "")) do
      {:error, :empty_label}
    else
      :ok
    end
  end

  defp to_ascii(host) do
    if ascii_ldh?(host) do
      {:ok, host}
    else
      ascii = host |> String.to_charlist() |> :idna.encode([:uts46, :std3_rules])
      {:ok, List.to_string(ascii)}
    end
  rescue
    _error -> {:error, :invalid_idna}
  catch
    _kind, _reason -> {:error, :invalid_idna}
  end

  defp ascii_ldh?(host), do: ascii_ldh?(host, 0)

  defp ascii_ldh?(<<>>, _label_position), do: true

  defp ascii_ldh?(<<".", rest::binary>>, _label_position), do: ascii_ldh?(rest, 0)

  defp ascii_ldh?(<<"--", _rest::binary>>, 2), do: false

  defp ascii_ldh?(<<byte, rest::binary>>, label_position)
       when byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte == ?-,
       do: ascii_ldh?(rest, label_position + 1)

  defp ascii_ldh?(_non_ldh, _label_position), do: false

  defp validate_ascii(""), do: {:error, :empty_domain}

  defp validate_ascii(ascii) do
    labels = String.split(ascii, ".", trim: false)

    cond do
      ip_literal?(ascii) -> {:error, :ip_literal}
      byte_size(ascii) > 253 -> {:error, :domain_too_long}
      Enum.any?(labels, &(&1 == "")) -> {:error, :empty_label}
      Enum.any?(labels, &(byte_size(&1) > 63)) -> {:error, :label_too_long}
      Enum.any?(labels, &invalid_label?/1) -> {:error, :invalid_label}
      true -> :ok
    end
  end

  defp ip_literal?(ascii) do
    match?({:ok, _address}, :inet.parse_address(String.to_charlist(ascii)))
  end

  defp invalid_label?(label) do
    String.starts_with?(label, "-") or
      String.ends_with?(label, "-") or
      not Regex.match?(~r/\A[a-z0-9-]+\z/, label)
  end
end
