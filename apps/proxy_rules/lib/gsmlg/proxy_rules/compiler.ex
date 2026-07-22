defmodule GSMLG.ProxyRules.Compiler do
  @moduledoc """
  Pure orchestration for one complete proxy-rules generation.

  The remote parser here intentionally supports only the temporary domain-anchor
  input needed to assemble artifacts. The full GFWList classifier replaces it
  in the next implementation slice.
  """

  alias GSMLG.ProxyRules.{
    Diagnostic,
    Domain,
    Hierarchy,
    Output,
    ParseResult,
    Renderer,
    Rule,
    Snapshot
  }

  alias GSMLG.ProxyRules.Parser.Local

  @type input :: %{
          required(:remote) => binary(),
          required(:local_proxy) => binary(),
          required(:local_direct) => binary()
        }
  @type compile_option ::
          {:generation, non_neg_integer()}
          | {:compiled_at, DateTime.t()}
          | {:sample_limit, non_neg_integer()}

  @spec compile(input(), [compile_option()]) :: {:ok, Snapshot.t()} | {:error, [Diagnostic.t()]}
  def compile(input, options) when is_list(options) do
    with {:ok, sources} <- validate_input(input),
         {:ok, generation, compiled_at, sample_limit} <- validate_options(options),
         {:ok, remote} <- parse_remote(sources.remote, sample_limit) do
      local_proxy = Local.parse(sources.local_proxy, :proxy, :local_proxy, sample_limit)
      local_direct = Local.parse(sources.local_direct, :direct, :local_direct, sample_limit)

      {:ok,
       build_snapshot(
         sources,
         remote,
         local_proxy,
         local_direct,
         generation,
         compiled_at,
         sample_limit
       )}
    end
  end

  def compile(_input, _options), do: {:error, [systemic(:gfwlist, :systemic_failure)]}

  defp validate_input(%{remote: remote, local_proxy: local_proxy, local_direct: local_direct}) do
    cond do
      not is_binary(remote) -> {:error, [systemic(:gfwlist, :systemic_failure)]}
      not is_binary(local_proxy) -> {:error, [systemic(:local_proxy, :systemic_failure)]}
      not is_binary(local_direct) -> {:error, [systemic(:local_direct, :systemic_failure)]}
      not String.valid?(local_proxy) -> {:error, [systemic(:local_proxy, :invalid_utf8)]}
      not String.valid?(local_direct) -> {:error, [systemic(:local_direct, :invalid_utf8)]}
      true -> {:ok, %{remote: remote, local_proxy: local_proxy, local_direct: local_direct}}
    end
  end

  defp validate_input(_input), do: {:error, [systemic(:gfwlist, :systemic_failure)]}

  defp validate_options(options) do
    generation = Keyword.get(options, :generation)
    compiled_at = Keyword.get(options, :compiled_at, DateTime.utc_now())
    sample_limit = Keyword.get(options, :sample_limit)

    if is_integer(generation) and generation >= 0 and valid_datetime?(compiled_at) and
         is_integer(sample_limit) and sample_limit >= 0 do
      {:ok, generation, DateTime.truncate(compiled_at, :second), sample_limit}
    else
      {:error, [systemic(:gfwlist, :systemic_failure)]}
    end
  end

  defp parse_remote(encoded, sample_limit) do
    with {:ok, decoded} <- decode_remote(encoded),
         true <- String.valid?(decoded) do
      {:ok, parse_remote_lines(decoded, sample_limit)}
    else
      :error -> {:error, [systemic(:gfwlist, :invalid_base64)]}
      false -> {:error, [systemic(:gfwlist, :invalid_utf8)]}
    end
  end

  defp decode_remote(encoded), do: Base.decode64(encoded)

  defp parse_remote_lines(text, sample_limit) do
    text
    |> String.split(~r/\R/u)
    |> Enum.with_index(1)
    |> Enum.reduce(%ParseResult{}, fn {raw_line, location}, result ->
      parse_remote_line(String.trim(raw_line), raw_line, location, result, sample_limit)
    end)
    |> reverse_parse_result()
  end

  defp parse_remote_line("", _raw, _location, result, _limit), do: result

  defp parse_remote_line(<<marker, _::binary>>, _raw, _location, result, _limit)
       when marker in [?!, ?#],
       do: result

  defp parse_remote_line("@@||" <> anchored, raw, location, result, limit),
    do: parse_anchor(anchored, raw, location, :direct, result, limit)

  defp parse_remote_line("||" <> anchored, raw, location, result, limit),
    do: parse_anchor(anchored, raw, location, :proxy, result, limit)

  defp parse_remote_line(_value, raw, location, result, limit) do
    add_diagnostic(result, :unsupported, :ambiguous_rule, raw, location, limit)
  end

  defp parse_anchor(anchored, raw, location, action, result, limit) do
    if String.ends_with?(anchored, "^") do
      domain = binary_part(anchored, 0, byte_size(anchored) - 1)
      add_remote_domain(domain, raw, location, action, result, limit)
    else
      add_diagnostic(result, :unsupported, :ambiguous_rule, raw, location, limit)
    end
  end

  defp add_remote_domain(value, raw, location, action, result, limit) do
    case Domain.normalize(value) do
      {:ok, domain} ->
        rule = %Rule{domain: domain, action: action, source: :gfwlist, location: location}

        %{
          result
          | rules: [rule | result.rules],
            counts: Map.update!(result.counts, :accepted, &(&1 + 1))
        }

      {:error, reason} ->
        add_diagnostic(result, :invalid, reason, raw, location, limit)
    end
  end

  defp add_diagnostic(result, kind, reason, raw, location, limit) do
    diagnostic = %Diagnostic{
      kind: kind,
      source: :gfwlist,
      location: location,
      reason: reason,
      sample: raw
    }

    diagnostics =
      if length(result.diagnostics) < limit,
        do: [diagnostic | result.diagnostics],
        else: result.diagnostics

    %{result | diagnostics: diagnostics, counts: Map.update!(result.counts, kind, &(&1 + 1))}
  end

  defp reverse_parse_result(result) do
    %{result | rules: Enum.reverse(result.rules), diagnostics: Enum.reverse(result.diagnostics)}
  end

  defp build_snapshot(
         sources,
         remote,
         local_proxy,
         local_direct,
         generation,
         compiled_at,
         sample_limit
       ) do
    proxy_rules = rules_for(remote, :proxy) ++ local_proxy.rules
    direct_rules = rules_for(remote, :direct) ++ local_direct.rules

    conflicts =
      proxy_rules
      |> domain_set()
      |> MapSet.intersection(domain_set(direct_rules))

    proxy = Hierarchy.fold_with_stats(proxy_rules)
    direct = Hierarchy.fold_with_stats(direct_rules)

    %Snapshot{
      generation: generation,
      compiled_at: compiled_at,
      readiness: :ready,
      source_versions: source_versions(sources),
      rendered_outputs: %{
        proxy: render_outputs(proxy.rules, compiled_at),
        direct: render_outputs(direct.rules, compiled_at)
      },
      statistics: %{
        sources: %{
          gfwlist: remote.counts,
          local_proxy: local_proxy.counts,
          local_direct: local_direct.counts
        },
        proxy_rule_count: length(proxy.rules),
        direct_rule_count: length(direct.rules),
        duplicate_count: proxy.duplicate_count + direct.duplicate_count,
        collapsed_count: proxy.collapsed_count + direct.collapsed_count,
        conflict_count: MapSet.size(conflicts)
      },
      diagnostics:
        Enum.take(
          remote.diagnostics ++ local_proxy.diagnostics ++ local_direct.diagnostics,
          sample_limit
        ),
      last_error: nil
    }
  end

  defp rules_for(result, action), do: Enum.filter(result.rules, &(&1.action == action))
  defp domain_set(rules), do: rules |> Enum.map(& &1.domain.name) |> MapSet.new()

  defp render_outputs(rules, compiled_at) do
    %{
      raw: rules |> Renderer.render(:raw) |> Output.new(compiled_at),
      squid: rules |> Renderer.render(:squid) |> Output.new(compiled_at),
      clash: rules |> Renderer.render(:clash) |> Output.new(compiled_at)
    }
  end

  defp source_versions(sources) do
    %{
      gfwlist: sha256(sources.remote),
      local_proxy: sha256(sources.local_proxy),
      local_direct: sha256(sources.local_direct)
    }
  end

  defp sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  defp valid_datetime?(%DateTime{} = datetime) do
    with {:ok, _date} <-
           Date.new(datetime.year, datetime.month, datetime.day, datetime.calendar),
         {:ok, _time} <-
           Time.new(
             datetime.hour,
             datetime.minute,
             datetime.second,
             datetime.microsecond,
             datetime.calendar
           ) do
      is_binary(datetime.time_zone) and datetime.time_zone != "" and
        is_binary(datetime.zone_abbr) and datetime.zone_abbr != "" and
        is_integer(datetime.utc_offset) and abs(datetime.utc_offset) < 86_400 and
        is_integer(datetime.std_offset) and abs(datetime.std_offset) < 86_400
    else
      {:error, _reason} -> false
    end
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp valid_datetime?(_datetime), do: false

  defp systemic(source, reason) do
    %Diagnostic{kind: :systemic, source: source, location: :system, reason: reason, sample: nil}
  end
end
