defmodule GSMLG.ProxyRules.Parser.Local do
  @moduledoc """
  Parses local proxy and direct domain lists.
  """

  alias GSMLG.ProxyRules.{Diagnostic, Domain, ParseResult, Rule}

  @diagnostic_sample_max_bytes 512
  @truncation_marker "...[truncated]"

  @spec parse(binary(), Rule.action(), Rule.source(), non_neg_integer()) :: ParseResult.t()
  def parse(text, action, source, sample_limit)
      when is_binary(text) and action in [:proxy, :direct] and
             source in [:gfwlist, :local_proxy, :local_direct] and
             is_integer(sample_limit) and sample_limit >= 0 do
    text
    |> String.split(~r/\R/u)
    |> Enum.with_index(1)
    |> Enum.reduce(%ParseResult{}, fn line, result ->
      parse_line(line, result, action, source, sample_limit)
    end)
    |> reverse_collections()
  end

  defp parse_line({raw_line, location}, result, action, source, sample_limit) do
    value = String.trim(raw_line)

    if ignored?(value) do
      result
    else
      case Domain.normalize(value) do
        {:ok, domain} ->
          rule = %Rule{
            domain: domain,
            action: action,
            source: source,
            location: location
          }

          %{result | rules: [rule | result.rules], counts: increment(result.counts, :accepted)}

        {:error, reason} ->
          diagnostic = %Diagnostic{
            kind: :invalid,
            source: source,
            location: location,
            reason: reason,
            sample: bounded_sample(raw_line)
          }

          %{
            result
            | diagnostics: retain_sample(result.diagnostics, diagnostic, sample_limit),
              counts: increment(result.counts, :invalid)
          }
      end
    end
  end

  defp ignored?(""), do: true
  defp ignored?(<<marker, _rest::binary>>) when marker in [?#, ?!], do: true
  defp ignored?(_value), do: false

  defp increment(counts, key), do: Map.update!(counts, key, &(&1 + 1))

  defp retain_sample(diagnostics, diagnostic, sample_limit) do
    if length(diagnostics) < sample_limit, do: [diagnostic | diagnostics], else: diagnostics
  end

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
end
