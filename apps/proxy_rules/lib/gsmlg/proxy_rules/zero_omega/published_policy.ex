defmodule GSMLG.ProxyRules.ZeroOmega.PublishedPolicy do
  @moduledoc """
  Compact domain-only policy stored in the immutable operational snapshot.

  Domain partitions are newline-encoded binaries so ETS readers share large
  reference-counted values instead of copying thousands of rule structs.
  """

  alias GSMLG.ProxyRules.ZeroOmega.{Diagnostic, Normalizer, Policy, Rule}

  @default_max_rules 100_000

  @enforce_keys [:revision, :direct_domains, :proxy_domains]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          revision: binary(),
          direct_domains: binary(),
          proxy_domains: binary()
        }

  @spec new(binary(), [binary()], [binary()]) :: t()
  def new(revision, direct_domains, proxy_domains)
      when is_binary(revision) and is_list(direct_domains) and is_list(proxy_domains) do
    %__MODULE__{
      revision: revision,
      direct_domains: encode_domains(direct_domains),
      proxy_domains: encode_domains(proxy_domains)
    }
  end

  @spec to_policy(t(), keyword()) :: {:ok, Policy.t()} | {:error, [Diagnostic.t()]}
  def to_policy(published, options \\ [])

  def to_policy(
        %__MODULE__{direct_domains: direct_body, proxy_domains: proxy_body} = published,
        options
      )
      when is_binary(direct_body) and is_binary(proxy_body) and is_list(options) do
    max_rules = Keyword.get(options, :max_rules, @default_max_rules)

    with true <- is_integer(max_rules) and max_rules >= 0,
         {:ok, direct_count} <- bounded_line_count(direct_body, max_rules),
         {:ok, _total_count} <- bounded_line_count(proxy_body, max_rules, direct_count) do
      direct = decode_rules(direct_body, :default, 0)
      proxy = decode_rules(proxy_body, :match, direct_count)

      %Policy{
        revision: published.revision,
        default_action: :default,
        rules: direct ++ proxy
      }
      |> Normalizer.normalize_policy()
    else
      _invalid -> too_many_rules()
    end
  end

  def to_policy(_published, _options) do
    {:error, [Diagnostic.error(:invalid_rule, "Published policy has an invalid shape")]}
  end

  @spec from_policy(Policy.t()) :: {:ok, t()} | {:error, [Diagnostic.t()]}
  def from_policy(%Policy{} = policy) do
    with :ok <- validate_operational_rules(policy.rules) do
      direct = domains_for(policy.rules, :default)
      proxy = domains_for(policy.rules, :match)
      {:ok, new(policy.revision, direct, proxy)}
    end
  end

  def from_policy(_policy) do
    {:error, [Diagnostic.error(:invalid_rule, "Canonical policy has an invalid shape")]}
  end

  defp encode_domains([]), do: ""
  defp encode_domains(domains), do: Enum.join(domains, "\n") <> "\n"

  defp decode_rules(body, action, offset) do
    body
    |> String.split("\n", trim: true)
    |> Enum.with_index(offset)
    |> Enum.map(fn {domain, index} ->
      %Rule{
        id: "#{action}:#{domain}",
        priority: index,
        enabled: true,
        condition: {:domain_suffix, domain},
        action: action,
        note: nil,
        input_order: index
      }
    end)
  end

  defp bounded_line_count(body, limit, count \\ 0)

  defp bounded_line_count(_body, limit, count) when count > limit,
    do: {:error, :too_many_rules}

  defp bounded_line_count(<<>>, _limit, count), do: {:ok, count}

  defp bounded_line_count(body, limit, count) do
    case :binary.match(body, "\n") do
      {index, 1} when count < limit ->
        rest_start = index + 1
        rest = binary_part(body, rest_start, byte_size(body) - rest_start)
        bounded_line_count(rest, limit, count + 1)

      {_index, 1} ->
        {:error, :too_many_rules}

      :nomatch ->
        if body == "", do: {:ok, count}, else: bounded_line_count(<<>>, limit, count + 1)
    end
  end

  defp validate_operational_rules(rules) when is_list(rules) do
    if Enum.all?(rules, fn
         %Rule{condition: {:domain_suffix, domain}, action: action}
         when is_binary(domain) and action in [:match, :default] ->
           true

         _unsupported ->
           false
       end) do
      :ok
    else
      {:error,
       [Diagnostic.error(:unsupported_condition, "Policy is not domain-only operational data")]}
    end
  end

  defp validate_operational_rules(_rules) do
    {:error, [Diagnostic.error(:invalid_rule, "Canonical policy rules must be a list")]}
  end

  defp domains_for(rules, action) do
    for %Rule{condition: {:domain_suffix, domain}, action: ^action} <- rules, do: domain
  end

  defp too_many_rules do
    {:error,
     [Diagnostic.error(:invalid_rule, "Published policy has too many rules", field: :rules)]}
  end
end
