defmodule GSMLG.ProxyRules.ZeroOmega.Normalizer do
  @moduledoc """
  Pure normalization and validation for canonical ZeroOmega policies.
  """

  alias GSMLG.ProxyRules.Domain
  alias GSMLG.ProxyRules.ZeroOmega.{Diagnostic, Policy, Rule, Text}

  @supported_conditions [
    :domain_suffix,
    :host_exact,
    :host_glob,
    :url_prefix,
    :url_glob,
    :url_regex,
    :cidr,
    :keyword
  ]

  @spec normalize_policy(Policy.t()) :: {:ok, Policy.t()} | {:error, [Diagnostic.t()]}
  def normalize_policy(%Policy{} = policy) do
    with {:ok, revision} <- normalize_policy_revision(policy.revision),
         :ok <- validate_default_action(policy.default_action),
         {:ok, rules} <- normalize_rules(policy.rules) do
      {:ok,
       %Policy{
         revision: revision,
         default_action: :default,
         rules: deduplicate(rules)
       }}
    else
      {:error, diagnostics} when is_list(diagnostics) -> {:error, diagnostics}
      {:error, %Diagnostic{} = diagnostic} -> {:error, [diagnostic]}
    end
  end

  def normalize_policy(_policy) do
    {:error, [Diagnostic.error(:invalid_rule, "Policy has an invalid shape")]}
  end

  defp normalize_policy_revision(revision) when is_binary(revision) do
    with :ok <- validate_text(revision, nil, :revision),
         normalized when normalized != "" <- String.trim(revision) do
      {:ok, normalized}
    else
      "" ->
        {:error, Diagnostic.error(:invalid_rule, "Revision must not be empty", field: :revision)}

      {:error, diagnostic} ->
        {:error, diagnostic}
    end
  end

  defp normalize_policy_revision(_revision) do
    {:error, Diagnostic.error(:invalid_rule, "Revision must be text", field: :revision)}
  end

  defp validate_default_action(:default), do: :ok

  defp validate_default_action(_action) do
    {:error,
     Diagnostic.error(:missing_default_profile, "Policy must define its default result",
       field: :default_action
     )}
  end

  defp normalize_rules(rules) when is_list(rules) do
    rules
    |> Enum.reject(&match?(%Rule{enabled: false}, &1))
    |> Enum.map(&normalize_rule/1)
    |> collect_results()
    |> sort_rules()
  end

  defp normalize_rules(_rules) do
    {:error, [Diagnostic.error(:invalid_rule, "Policy rules must be a list", field: :rules)]}
  end

  defp normalize_rule(%Rule{} = rule) do
    results = [
      normalize_id(rule.id),
      validate_non_negative_integer(rule.priority, rule.id, :priority),
      validate_enabled(rule.enabled, rule.id),
      normalize_note(rule.note, rule.id),
      normalize_condition(rule.condition, rule.id),
      normalize_action(rule.action, rule.id),
      validate_non_negative_integer(rule.input_order, rule.id, :input_order)
    ]

    case collect_fields(results) do
      {:ok, [id, priority, true, note, condition, action, input_order]} ->
        {:ok,
         %Rule{
           id: id,
           priority: priority,
           enabled: true,
           note: note,
           condition: condition,
           action: action,
           input_order: input_order
         }}

      {:error, diagnostics} ->
        {:error, diagnostics}
    end
  end

  defp normalize_rule(_rule) do
    {:error, [Diagnostic.error(:invalid_rule, "Rule has an invalid shape")]}
  end

  defp normalize_id(id) when is_binary(id) do
    with :ok <- validate_text(id, nil, :id),
         normalized when normalized != "" <- String.trim(id) do
      {:ok, normalized}
    else
      "" -> {:error, Diagnostic.error(:invalid_rule, "Rule id must not be empty", field: :id)}
      {:error, diagnostic} -> {:error, diagnostic}
    end
  end

  defp normalize_id(_id),
    do: {:error, Diagnostic.error(:invalid_rule, "Rule id must be text", field: :id)}

  defp validate_non_negative_integer(value, _rule_id, _field)
       when is_integer(value) and value >= 0,
       do: {:ok, value}

  defp validate_non_negative_integer(_value, rule_id, field) do
    {:error,
     Diagnostic.error(:invalid_rule, "Rule ordering value must be a non-negative integer",
       rule_id: safe_rule_id(rule_id),
       field: field
     )}
  end

  defp validate_enabled(value, _rule_id) when is_boolean(value), do: {:ok, value}

  defp validate_enabled(_value, rule_id) do
    {:error,
     Diagnostic.error(:invalid_rule, "Rule enabled value must be boolean",
       rule_id: safe_rule_id(rule_id),
       field: :enabled
     )}
  end

  defp normalize_note(nil, _rule_id), do: {:ok, nil}

  defp normalize_note(note, rule_id) when is_binary(note) do
    case validate_text(note, rule_id, :note) do
      :ok ->
        case String.trim(note) do
          "" -> {:ok, nil}
          normalized -> {:ok, normalized}
        end

      {:error, diagnostic} ->
        {:error, diagnostic}
    end
  end

  defp normalize_note(_note, rule_id) do
    {:error,
     Diagnostic.error(:invalid_rule, "Rule note must be text",
       rule_id: safe_rule_id(rule_id),
       field: :note
     )}
  end

  defp normalize_condition({kind, value}, rule_id)
       when kind in @supported_conditions and is_binary(value) do
    case validate_text(value, rule_id, :condition) do
      :ok -> do_normalize_condition(kind, String.trim(value), rule_id)
      {:error, diagnostic} -> {:error, diagnostic}
    end
  end

  defp normalize_condition({kind, _value}, rule_id) when kind in @supported_conditions do
    {:error,
     Diagnostic.error(condition_error_code(kind), "Condition value must be text",
       rule_id: safe_rule_id(rule_id),
       field: :condition
     )}
  end

  defp normalize_condition(_condition, rule_id) do
    {:error,
     Diagnostic.error(:unsupported_condition, "Condition type is not supported",
       rule_id: safe_rule_id(rule_id),
       field: :condition
     )}
  end

  defp do_normalize_condition(kind, "", rule_id) do
    {:error,
     Diagnostic.error(condition_error_code(kind), "Condition must not be empty",
       rule_id: safe_rule_id(rule_id),
       field: :condition
     )}
  end

  defp do_normalize_condition(:domain_suffix, value, rule_id),
    do: normalize_domain_condition(:domain_suffix, value, rule_id)

  defp do_normalize_condition(:host_exact, value, rule_id),
    do: normalize_domain_condition(:host_exact, value, rule_id)

  defp do_normalize_condition(:host_glob, value, rule_id) do
    with {:ok, glob} <- normalize_host_glob(value) do
      {:ok, {:host_glob, glob}}
    else
      {:error, _reason} ->
        {:error,
         Diagnostic.error(:invalid_domain, "Host glob is invalid",
           rule_id: safe_rule_id(rule_id),
           field: :condition
         )}
    end
  end

  defp do_normalize_condition(:url_prefix, value, rule_id) do
    with {:ok, url} <- normalize_url(value) do
      {:ok, {:url_prefix, url}}
    else
      {:error, _reason} -> invalid_url(rule_id)
    end
  end

  defp do_normalize_condition(:url_glob, value, rule_id) do
    with {:ok, url_glob} <- normalize_url_glob(value) do
      {:ok, {:url_glob, url_glob}}
    else
      {:error, _reason} -> invalid_url(rule_id)
    end
  end

  defp do_normalize_condition(:url_regex, value, rule_id) do
    case Regex.compile(value) do
      {:ok, _regex} -> {:ok, {:url_regex, value}}
      {:error, _reason} -> invalid_regex(rule_id)
    end
  end

  defp do_normalize_condition(:cidr, value, rule_id) do
    case validate_cidr(value) do
      :ok -> {:ok, {:cidr, value}}
      {:error, _reason} -> invalid_cidr(rule_id)
    end
  end

  defp do_normalize_condition(:keyword, value, _rule_id), do: {:ok, {:keyword, value}}

  defp normalize_domain_condition(kind, value, rule_id) do
    case Domain.normalize(value) do
      {:ok, domain} ->
        {:ok, {kind, domain.name}}

      {:error, _reason} ->
        {:error,
         Diagnostic.error(:invalid_domain, "Domain or host is invalid",
           rule_id: safe_rule_id(rule_id),
           field: :condition
         )}
    end
  end

  defp normalize_host_glob(value) do
    value = remove_trailing_dot(value)

    cond do
      value == "" -> {:error, :empty}
      String.contains?(value, ["/", ":", "?", "&", "="]) -> {:error, :invalid}
      special_leading_glob?(value) -> {:ok, value}
      true -> normalize_host_glob_labels(String.split(value, ".", trim: false))
    end
  end

  defp normalize_host_glob_labels(labels) do
    Enum.reduce_while(labels, {:ok, []}, fn label, {:ok, normalized} ->
      case normalize_host_glob_label(label) do
        {:ok, value} -> {:cont, {:ok, [value | normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, normalized |> Enum.reverse() |> Enum.join(".")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_host_glob_label(""), do: {:error, :empty_label}

  defp normalize_host_glob_label(label) do
    if String.contains?(label, "*") do
      normalized = String.downcase(label)

      if Regex.match?(~r/\A[a-z0-9*-]+\z/, normalized) and
           not String.starts_with?(normalized, "-") and
           not String.ends_with?(normalized, "-") do
        {:ok, normalized}
      else
        {:error, :invalid_label}
      end
    else
      case Domain.normalize(label) do
        {:ok, domain} -> {:ok, domain.name}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp special_leading_glob?(<<leading, _rest::binary>>), do: leading in ~c"[;#@!+"
  defp special_leading_glob?(<<>>), do: false

  defp normalize_url(value) do
    uri = URI.parse(value)
    scheme = uri.scheme && String.downcase(uri.scheme)

    with true <- scheme in ["http", "https"],
         true <- is_binary(uri.host) and uri.host != "",
         true <- is_nil(uri.userinfo),
         {:ok, domain} <- Domain.normalize(uri.host) do
      authority = domain.name <> if(uri.port, do: ":#{uri.port}", else: "")

      {:ok, URI.to_string(%{uri | scheme: scheme, host: domain.name, authority: authority})}
    else
      _invalid -> {:error, :invalid_url}
    end
  rescue
    ArgumentError -> {:error, :invalid_url}
  end

  defp normalize_url_glob(value) do
    case Regex.run(~r/\A([A-Za-z][A-Za-z0-9+.-]*):\/\/([^\/?#]+)(.*)\z/, value,
           capture: :all_but_first
         ) do
      [scheme, host_glob, suffix] ->
        with true <- String.downcase(scheme) in ["http", "https"],
             {:ok, normalized_host} <- normalize_host_glob(host_glob) do
          {:ok, String.downcase(scheme) <> "://" <> normalized_host <> suffix}
        else
          _invalid -> {:error, :invalid_url}
        end

      nil ->
        {:error, :invalid_url}
    end
  end

  defp validate_cidr(value) do
    case String.split(value, "/", parts: 2) do
      [address, prefix_text] ->
        with {:ok, parsed} <- :inet.parse_address(String.to_charlist(address)),
             {prefix, ""} <- Integer.parse(prefix_text),
             true <- prefix >= 0 and prefix <= address_bits(parsed) do
          :ok
        else
          _invalid -> {:error, :invalid_cidr}
        end

      _invalid ->
        {:error, :invalid_cidr}
    end
  end

  defp address_bits(address) when tuple_size(address) == 4, do: 32
  defp address_bits(address) when tuple_size(address) == 8, do: 128

  defp normalize_action(action, _rule_id) when action in [:match, :default], do: {:ok, action}

  defp normalize_action({:profile, profile}, rule_id) when is_binary(profile) do
    with :ok <- validate_text(profile, rule_id, :action),
         normalized when normalized != "" <- String.trim(profile),
         false <- String.contains?(normalized, "+") do
      {:ok, {:profile, normalized}}
    else
      "" -> ambiguous_profile(rule_id)
      true -> ambiguous_profile(rule_id)
      {:error, _diagnostic} -> ambiguous_profile(rule_id)
    end
  end

  defp normalize_action({:profile, _profile}, rule_id), do: ambiguous_profile(rule_id)

  defp normalize_action(_action, rule_id) do
    {:error,
     Diagnostic.error(:unsupported_action, "Rule action is not supported",
       rule_id: safe_rule_id(rule_id),
       field: :action
     )}
  end

  defp validate_text(value, rule_id, field) do
    if Text.safe_line?(value) do
      :ok
    else
      {:error,
       Diagnostic.error(:line_injection, "Text contains forbidden control characters",
         rule_id: safe_rule_id(rule_id),
         field: field
       )}
    end
  end

  defp collect_fields(results) do
    {values, diagnostics} =
      Enum.reduce(results, {[], []}, fn
        {:ok, value}, {values, diagnostics} ->
          {[value | values], diagnostics}

        {:error, %Diagnostic{} = diagnostic}, {values, diagnostics} ->
          {values, [diagnostic | diagnostics]}
      end)

    case diagnostics do
      [] -> {:ok, Enum.reverse(values)}
      diagnostics -> {:error, Enum.reverse(diagnostics)}
    end
  end

  defp collect_results(results) do
    {rules, diagnostics} =
      Enum.reduce(results, {[], []}, fn
        {:ok, rule}, {rules, diagnostics} ->
          {[rule | rules], diagnostics}

        {:error, rule_diagnostics}, {rules, diagnostics} ->
          {rules, Enum.reverse(rule_diagnostics, diagnostics)}
      end)

    case diagnostics do
      [] -> {:ok, Enum.reverse(rules)}
      diagnostics -> {:error, Enum.reverse(diagnostics)}
    end
  end

  defp sort_rules({:ok, rules}), do: {:ok, Enum.sort_by(rules, &{&1.priority, &1.input_order})}
  defp sort_rules({:error, diagnostics}), do: {:error, diagnostics}

  defp deduplicate(rules) do
    {deduplicated, _seen} =
      Enum.reduce(rules, {[], MapSet.new()}, fn rule, {acc, seen} ->
        key = {rule.condition, rule.action}

        if MapSet.member?(seen, key) do
          {acc, seen}
        else
          {[rule | acc], MapSet.put(seen, key)}
        end
      end)

    Enum.reverse(deduplicated)
  end

  defp remove_trailing_dot(value) do
    if String.ends_with?(value, "."),
      do: binary_part(value, 0, byte_size(value) - 1),
      else: value
  end

  defp invalid_url(rule_id) do
    {:error,
     Diagnostic.error(:invalid_url, "URL condition is invalid",
       rule_id: safe_rule_id(rule_id),
       field: :condition
     )}
  end

  defp invalid_regex(rule_id) do
    {:error,
     Diagnostic.error(:invalid_regex, "Regular expression is invalid",
       rule_id: safe_rule_id(rule_id),
       field: :condition
     )}
  end

  defp invalid_cidr(rule_id) do
    {:error,
     Diagnostic.error(:invalid_cidr, "CIDR condition is invalid",
       rule_id: safe_rule_id(rule_id),
       field: :condition
     )}
  end

  defp ambiguous_profile(rule_id) do
    {:error,
     Diagnostic.error(:ambiguous_profile_name, "Profile name is ambiguous",
       rule_id: safe_rule_id(rule_id),
       field: :action
     )}
  end

  defp condition_error_code(kind) when kind in [:domain_suffix, :host_exact, :host_glob],
    do: :invalid_domain

  defp condition_error_code(kind) when kind in [:url_prefix, :url_glob], do: :invalid_url
  defp condition_error_code(:url_regex), do: :invalid_regex
  defp condition_error_code(:cidr), do: :invalid_cidr
  defp condition_error_code(:keyword), do: :unsupported_condition

  defp safe_rule_id(rule_id) when is_binary(rule_id) do
    if String.valid?(rule_id) and
         not Enum.any?(:binary.bin_to_list(rule_id), &(&1 < 32 or &1 == 127)) do
      String.slice(String.trim(rule_id), 0, 128)
    end
  end

  defp safe_rule_id(_rule_id), do: nil
end
