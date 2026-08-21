defmodule GSMLG.ProxyRules.Compiler do
  @moduledoc """
  Pure orchestration for one complete proxy-rules generation.

  Each input is parsed independently before accepted proxy and direct rules are
  merged, folded, and rendered into one immutable snapshot.
  """

  alias GSMLG.ProxyRules.{
    Diagnostic,
    Hierarchy,
    Output,
    Renderer,
    Snapshot
  }

  alias GSMLG.ProxyRules.Parser.{GFWList, Local}
  alias GSMLG.ProxyRules.ZeroOmega.{Normalizer, PAC, PublishedPolicy, Switchy}

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
         {:ok, remote, remote_metadata} <- parse_remote(sources.remote, sample_limit) do
      local_proxy = Local.parse(sources.local_proxy, :proxy, :local_proxy, sample_limit)
      local_direct = Local.parse(sources.local_direct, :direct, :local_direct, sample_limit)

      build_snapshot(
        sources,
        remote,
        remote_metadata,
        local_proxy,
        local_direct,
        generation,
        compiled_at,
        sample_limit
      )
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
    case GFWList.parse(encoded, sample_limit) do
      {:ok, result, metadata} -> {:ok, result, metadata}
      {:error, reason} -> {:error, [systemic(:gfwlist, reason)]}
    end
  end

  defp build_snapshot(
         sources,
         remote,
         remote_metadata,
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

    case build_zeroomega_policy(direct.rules, proxy.rules, generation) do
      {:ok, zeroomega_policy} ->
        {:ok,
         %Snapshot{
           generation: generation,
           compiled_at: compiled_at,
           readiness: :ready,
           source_versions: source_versions(sources, remote_metadata),
           rendered_outputs: %{
             proxy: render_outputs(proxy.rules, compiled_at),
             direct: render_outputs(direct.rules, compiled_at)
           },
           zeroomega_policy: zeroomega_policy,
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
         }}

      {:error, _diagnostics} ->
        {:error, [systemic(:gfwlist, :systemic_failure)]}
    end
  end

  defp build_zeroomega_policy(direct_rules, proxy_rules, generation) do
    published =
      PublishedPolicy.new(
        Integer.to_string(generation),
        Enum.map(direct_rules, & &1.domain.name),
        Enum.map(proxy_rules, & &1.domain.name)
      )

    with {:ok, policy} <- PublishedPolicy.to_policy(published),
         {:ok, normalized} <- Normalizer.normalize_policy(policy),
         {:ok, _body} <- Switchy.render(normalized),
         :ok <- PAC.validate_policy(normalized) do
      {:ok, published}
    end
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

  defp source_versions(sources, remote_metadata) do
    %{
      gfwlist: remote_metadata.decoded_sha256,
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
