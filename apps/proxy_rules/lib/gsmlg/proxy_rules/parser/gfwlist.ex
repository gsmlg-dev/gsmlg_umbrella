defmodule GSMLG.ProxyRules.Parser.GFWList do
  @moduledoc """
  Decodes and conservatively extracts suffix-domain rules from GFWList.

  Unsupported Adblock constructs are counted without being broadened into a
  domain rule. Malformed candidates are counted as invalid. Retained diagnostic
  samples are capped at 512 bytes, including the truncation marker.
  """

  alias GSMLG.ProxyRules.{Diagnostic, Domain, ParseResult, Rule}

  @diagnostic_sample_max_bytes 512
  @truncation_marker "...[truncated]"

  @type metadata :: %{required(:decoded_sha256) => binary()}

  @spec decode(binary()) :: {:ok, binary()} | {:error, :invalid_base64 | :invalid_utf8}
  def decode(body) when is_binary(body) do
    case Base.decode64(body, ignore: :whitespace) do
      {:ok, decoded} ->
        if String.valid?(decoded), do: {:ok, decoded}, else: {:error, :invalid_utf8}

      :error ->
        {:error, :invalid_base64}
    end
  end

  def decode(_body), do: {:error, :invalid_base64}

  @spec parse(binary(), non_neg_integer()) ::
          {:ok, ParseResult.t(), metadata()} | {:error, :invalid_base64 | :invalid_utf8}
  def parse(body, sample_limit)
      when is_binary(body) and is_integer(sample_limit) and sample_limit >= 0 do
    with {:ok, decoded} <- decode(body) do
      result =
        decoded
        |> String.split(~r/\R/u)
        |> Enum.with_index(1)
        |> Enum.reduce(%ParseResult{}, fn line, result ->
          parse_line(line, result, sample_limit)
        end)
        |> reverse_collections()

      {:ok, result, %{decoded_sha256: sha256(decoded)}}
    end
  end

  defp parse_line({raw_line, location}, result, sample_limit) do
    value = String.trim(raw_line)

    case classify(value) do
      :ignored ->
        result

      {:candidate, action, candidate} ->
        add_candidate(result, action, candidate, raw_line, location, sample_limit)

      {:unsupported, reason} ->
        add_diagnostic(
          result,
          :unsupported,
          reason,
          raw_line,
          location,
          sample_limit
        )
    end
  end

  defp classify(""), do: :ignored
  defp classify(<<marker, _rest::binary>>) when marker == ?!, do: :ignored

  defp classify(value) do
    cond do
      metadata?(value) -> :ignored
      cosmetic_or_hash_syntax?(value) -> {:unsupported, :ambiguous_rule}
      String.contains?(value, "$") -> {:unsupported, :modifier}
      String.contains?(value, "*") -> {:unsupported, :wildcard}
      regular_expression?(value) -> {:unsupported, :regular_expression}
      String.starts_with?(value, "@@||") -> classify_anchor(value, :direct, 4)
      String.starts_with?(value, "||") -> classify_anchor(value, :proxy, 2)
      String.starts_with?(value, "@@") -> {:unsupported, :ambiguous_rule}
      http_rule?(value) -> classify_http_rule(value)
      String.contains?(value, "://") -> {:unsupported, :ambiguous_rule}
      String.contains?(value, ["/", "?", "#"]) -> {:unsupported, :path_specific}
      plain_domain?(value) -> {:candidate, :proxy, value}
      true -> {:unsupported, :ambiguous_rule}
    end
  end

  defp metadata?(value),
    do: String.starts_with?(value, "[") and String.ends_with?(value, "]")

  defp cosmetic_or_hash_syntax?(value) do
    String.starts_with?(value, "#") or String.contains?(value, ["##", "#@#"])
  end

  defp regular_expression?(value),
    do:
      byte_size(value) >= 2 and String.starts_with?(value, "/") and String.ends_with?(value, "/")

  defp classify_anchor(value, action, prefix_size) do
    candidate = binary_part(value, prefix_size, byte_size(value) - prefix_size)
    candidate = remove_terminal_separator(candidate)

    cond do
      String.contains?(candidate, "^") -> {:unsupported, :ambiguous_rule}
      String.contains?(candidate, ["/", "?", "#", "|"]) -> {:unsupported, :path_specific}
      true -> {:candidate, action, candidate}
    end
  end

  defp remove_terminal_separator(candidate) do
    if String.ends_with?(candidate, "^") do
      binary_part(candidate, 0, byte_size(candidate) - 1)
    else
      candidate
    end
  end

  defp http_rule?(value) do
    String.starts_with?(value, ["http://", "https://", "|http://", "|https://"])
  end

  defp classify_http_rule(value) do
    normalized = remove_leading_separator(value)

    if String.contains?(normalized, "|") do
      {:unsupported, :ambiguous_rule}
    else
      classify_normalized_http_rule(normalized)
    end
  end

  defp remove_leading_separator("|" <> rest), do: rest
  defp remove_leading_separator(value), do: value

  defp classify_normalized_http_rule(value) do
    uri = URI.parse(value)

    cond do
      explicit_port?(uri) ->
        {:unsupported, :ambiguous_rule}

      uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
        uri.userinfo == nil and uri.query == nil and uri.fragment == nil and
          uri.path in [nil, "", "/"] ->
        {:candidate, :proxy, value}

      true ->
        {:unsupported, :path_specific}
    end
  end

  defp explicit_port?(%URI{authority: authority}) when is_binary(authority),
    do: String.contains?(authority, ":")

  defp explicit_port?(_uri), do: false

  defp plain_domain?(value) do
    String.contains?(value, ".") and Regex.match?(~r/\A[^\s:|^]+\z/u, value)
  end

  defp add_candidate(result, action, candidate, raw, location, sample_limit) do
    case Domain.normalize(candidate) do
      {:ok, domain} ->
        rule = %Rule{
          domain: domain,
          action: action,
          source: :gfwlist,
          location: location
        }

        %{result | rules: [rule | result.rules], counts: increment(result.counts, :accepted)}

      {:error, reason} ->
        add_diagnostic(result, :invalid, reason, raw, location, sample_limit)
    end
  end

  defp add_diagnostic(result, kind, reason, raw, location, sample_limit) do
    diagnostic = %Diagnostic{
      kind: kind,
      source: :gfwlist,
      location: location,
      reason: reason,
      sample: bounded_sample(raw)
    }

    diagnostics =
      if length(result.diagnostics) < sample_limit,
        do: [diagnostic | result.diagnostics],
        else: result.diagnostics

    %{result | diagnostics: diagnostics, counts: increment(result.counts, kind)}
  end

  defp increment(counts, key), do: Map.update!(counts, key, &(&1 + 1))

  defp bounded_sample(raw) when byte_size(raw) <= @diagnostic_sample_max_bytes, do: raw

  defp bounded_sample(raw) do
    prefix_size = @diagnostic_sample_max_bytes - byte_size(@truncation_marker)

    raw
    |> binary_part(0, prefix_size)
    |> trim_incomplete_utf8()
    |> Kernel.<>(@truncation_marker)
  end

  defp trim_incomplete_utf8(prefix) do
    if String.valid?(prefix) do
      prefix
    else
      trim_incomplete_utf8(binary_part(prefix, 0, byte_size(prefix) - 1))
    end
  end

  defp reverse_collections(result) do
    %{result | rules: Enum.reverse(result.rules), diagnostics: Enum.reverse(result.diagnostics)}
  end

  defp sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
end
