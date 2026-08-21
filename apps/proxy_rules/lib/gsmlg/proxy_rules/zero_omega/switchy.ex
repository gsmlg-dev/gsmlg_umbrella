defmodule GSMLG.ProxyRules.ZeroOmega.Switchy do
  @moduledoc """
  Pure SwitchyOmega Conditions renderer.
  """

  alias GSMLG.ProxyRules.ZeroOmega.{Diagnostic, Policy, Rule, Text}

  @special_host_glob_leaders ~c"[;#@!+"

  @type mode :: :binary | :result

  @spec render(Policy.t(), keyword()) :: {:ok, binary()} | {:error, [Diagnostic.t()]}
  def render(policy, options \\ [])

  def render(%Policy{} = policy, options) when is_list(options) do
    with {:ok, settings} <- validate_options(options),
         {:ok, lines} <- render_rules(policy.rules, settings) do
      {:ok, render_document(lines, settings)}
    end
  end

  def render(_policy, _options) do
    {:error, [Diagnostic.error(:invalid_rule, "Switchy policy or options are invalid")]}
  end

  defp validate_options(options) do
    mode = Keyword.get(options, :mode, :binary)
    match_profile = Keyword.get(options, :match_profile, "squid")
    default_profile = Keyword.get(options, :default_profile, "direct")

    with true <- mode in [:binary, :result],
         {:ok, normalized_match} <- normalize_profile(match_profile),
         {:ok, normalized_default} <- normalize_profile(default_profile),
         true <- normalized_match != normalized_default do
      {:ok, %{mode: mode, match_profile: normalized_match, default_profile: normalized_default}}
    else
      _invalid ->
        {:error,
         [Diagnostic.error(:ambiguous_profile_name, "Switchy profile options are ambiguous")]}
    end
  end

  defp normalize_profile(profile) when is_binary(profile) do
    normalized = String.trim(profile)

    if normalized != "" and Text.safe_line?(normalized) and
         not String.contains?(normalized, "+") do
      {:ok, normalized}
    else
      {:error, :ambiguous_profile_name}
    end
  end

  defp normalize_profile(_profile), do: {:error, :ambiguous_profile_name}

  defp render_rules(rules, settings) when is_list(rules) do
    {rendered, diagnostics} =
      Enum.reduce(rules, {[], []}, fn
        %Rule{} = rule, {lines, diagnostics} ->
          case render_rule(rule, settings) do
            {:ok, rule_lines} -> {Enum.reverse(rule_lines, lines), diagnostics}
            {:error, diagnostic} -> {lines, [diagnostic | diagnostics]}
          end

        _invalid_rule, {lines, diagnostics} ->
          diagnostic = Diagnostic.error(:invalid_rule, "Switchy rule has an invalid shape")
          {lines, [diagnostic | diagnostics]}
      end)

    case diagnostics do
      [] -> {:ok, Enum.reverse(rendered)}
      diagnostics -> {:error, Enum.reverse(diagnostics)}
    end
  end

  defp render_rules(_rules, _settings) do
    {:error, [Diagnostic.error(:invalid_rule, "Switchy rules must be a list")]}
  end

  defp render_rule(%Rule{} = rule, settings) do
    with {:ok, condition} <- render_condition(rule.condition, rule.id),
         {:ok, line} <- render_action(condition, rule.action, rule.id, settings) do
      {:ok, maybe_note(rule.note) ++ [line]}
    end
  end

  defp render_condition({:domain_suffix, domain}, _rule_id), do: {:ok, "*." <> domain}
  defp render_condition({:host_exact, host}, _rule_id), do: {:ok, host}

  defp render_condition({:host_glob, <<leading, _rest::binary>> = glob}, _rule_id)
       when leading in @special_host_glob_leaders,
       do: {:ok, ": " <> glob}

  defp render_condition({:host_glob, glob}, _rule_id),
    do: {:ok, "HostWildcard: " <> glob}

  defp render_condition({:url_prefix, prefix}, _rule_id) do
    suffix = if String.ends_with?(prefix, "*"), do: prefix, else: prefix <> "*"
    {:ok, "UrlWildcard: " <> suffix}
  end

  defp render_condition({:url_glob, glob}, _rule_id), do: {:ok, "UrlWildcard: " <> glob}
  defp render_condition({:url_regex, regex}, _rule_id), do: {:ok, "UrlRegex: " <> regex}
  defp render_condition({:cidr, cidr}, _rule_id), do: {:ok, "Ip: " <> cidr}
  defp render_condition({:keyword, keyword}, _rule_id), do: {:ok, "Keyword: " <> keyword}

  defp render_condition(_condition, rule_id) do
    {:error,
     Diagnostic.error(:unsupported_condition, "Condition cannot be rendered by Switchy",
       rule_id: rule_id,
       field: :condition
     )}
  end

  defp render_action(condition, action, rule_id, %{mode: :binary} = settings) do
    case action_result(action, settings) do
      :match -> {:ok, condition}
      :default -> {:ok, "!" <> condition}
      :unsupported -> unsupported_action(rule_id)
    end
  end

  defp render_action(condition, action, _rule_id, %{mode: :result} = settings) do
    case action_result(action, settings) do
      :match -> {:ok, condition <> " +" <> settings.match_profile}
      :default -> {:ok, "!" <> condition}
      {:profile, profile} -> {:ok, condition <> " +" <> profile}
    end
  end

  defp action_result(:match, _settings), do: :match
  defp action_result(:default, _settings), do: :default

  defp action_result({:profile, profile}, settings) do
    cond do
      profile == settings.match_profile -> :match
      profile == settings.default_profile -> :default
      settings.mode == :result -> {:profile, profile}
      true -> :unsupported
    end
  end

  defp action_result(_action, _settings), do: :unsupported

  defp maybe_note(nil), do: []
  defp maybe_note(note), do: ["@note " <> note]

  defp render_document(lines, %{mode: :binary}) do
    join_lines(["[SwitchyOmega Conditions]", "" | lines])
  end

  defp render_document(lines, %{mode: :result, default_profile: default_profile}) do
    join_lines(
      ["[SwitchyOmega Conditions]", "@with result", ""] ++
        lines ++ ["", "* +" <> default_profile]
    )
  end

  defp join_lines(lines), do: Enum.join(lines, "\r\n") <> "\r\n"

  defp unsupported_action(rule_id) do
    {:error,
     Diagnostic.error(:unsupported_action, "Action cannot be rendered in Switchy binary mode",
       rule_id: rule_id,
       field: :action
     )}
  end
end
