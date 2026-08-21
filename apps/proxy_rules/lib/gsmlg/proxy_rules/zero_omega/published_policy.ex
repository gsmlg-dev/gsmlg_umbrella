defmodule GSMLG.ProxyRules.ZeroOmega.PublishedPolicy do
  @moduledoc """
  Compact domain-only policy stored in the immutable operational snapshot.

  Domain partitions are newline-encoded binaries so ETS readers share large
  reference-counted values instead of copying thousands of rule structs.
  """

  alias GSMLG.ProxyRules.ZeroOmega.{Diagnostic, Normalizer, Policy, Rule}

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

  @spec to_policy(t()) :: {:ok, Policy.t()} | {:error, [Diagnostic.t()]}
  def to_policy(%__MODULE__{direct_domains: direct, proxy_domains: proxy} = published)
      when is_binary(direct) and is_binary(proxy) do
    direct = decode_rules(published.direct_domains, :default, 0)
    proxy = decode_rules(published.proxy_domains, :match, length(direct))

    %Policy{
      revision: published.revision,
      default_action: :default,
      rules: direct ++ proxy
    }
    |> Normalizer.normalize_policy()
  end

  def to_policy(_published) do
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
end
