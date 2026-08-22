defmodule GSMLG.ProxyRules.ZeroOmega.PAC do
  @moduledoc """
  Pure parameterized PAC renderer for the domain-only operational policy.
  """

  alias GSMLG.ProxyRules.Domain
  alias GSMLG.ProxyRules.ZeroOmega.{Diagnostic, Policy, Rule, Text}

  @spec normalize_proxy(binary()) :: {:ok, binary()} | {:error, Diagnostic.t()}
  def normalize_proxy(proxy) when is_binary(proxy) do
    if valid_proxy_text?(proxy) do
      parse_proxy(proxy)
    else
      invalid_proxy()
    end
  end

  def normalize_proxy(_proxy), do: invalid_proxy()

  @spec validate_policy(Policy.t()) :: :ok | {:error, [Diagnostic.t()]}
  def validate_policy(%Policy{default_action: :default, rules: rules}) when is_list(rules) do
    diagnostics = Enum.flat_map(rules, &validate_rule/1)
    if diagnostics == [], do: :ok, else: {:error, diagnostics}
  end

  def validate_policy(_policy) do
    {:error, [Diagnostic.error(:missing_default_profile, "PAC policy must default directly")]}
  end

  @spec render(Policy.t(), keyword()) :: {:ok, binary()} | {:error, [Diagnostic.t()]}
  def render(%Policy{} = policy, options) when is_list(options) do
    with {:ok, proxy_value} <- normalize_proxy_option(options),
         :ok <- validate_policy(policy) do
      {:ok, render_document(policy.rules, proxy_value)}
    else
      {:error, %Diagnostic{} = diagnostic} -> {:error, [diagnostic]}
      {:error, diagnostics} when is_list(diagnostics) -> {:error, diagnostics}
    end
  end

  def render(_policy, _options) do
    {:error, [Diagnostic.error(:invalid_rule, "PAC policy or options are invalid")]}
  end

  defp normalize_proxy_option(options) do
    case Keyword.fetch(options, :proxy) do
      {:ok, proxy} -> normalize_proxy(proxy)
      :error -> invalid_proxy()
    end
  end

  defp valid_proxy_text?(proxy) do
    proxy != "" and Text.safe_line?(proxy) and
      not Regex.match?(~r/\s/u, proxy) and
      not String.contains?(proxy, ["'", "\"", "\\", "/", "@", "?", "#"])
  end

  defp parse_proxy(proxy) do
    case Regex.run(~r/\A\[([0-9A-Fa-f:.]+)\]:(\d{1,5})\z/, proxy, capture: :all_but_first) do
      [address, port] -> normalize_ipv6_proxy(address, port)
      nil -> normalize_host_proxy(proxy)
    end
  end

  defp normalize_ipv6_proxy(address, port_text) do
    with {:ok, parsed} <- :inet.parse_address(String.to_charlist(address)),
         true <- tuple_size(parsed) == 8,
         {:ok, port} <- normalize_port(port_text) do
      canonical_address = parsed |> :inet.ntoa() |> List.to_string()
      {:ok, "[#{canonical_address}]:#{port}"}
    else
      _invalid -> invalid_proxy()
    end
  end

  defp normalize_host_proxy(proxy) do
    case Regex.run(~r/\A([^:]+):(\d{1,5})\z/u, proxy, capture: :all_but_first) do
      [host, port_text] ->
        with {:ok, normalized_host} <- normalize_proxy_host(host),
             {:ok, port} <- normalize_port(port_text) do
          {:ok, "#{normalized_host}:#{port}"}
        else
          _invalid -> invalid_proxy()
        end

      nil ->
        invalid_proxy()
    end
  end

  defp normalize_proxy_host(host) do
    cond do
      String.starts_with?(host, ".") ->
        {:error, :invalid_host}

      match?({:ok, _address}, :inet.parse_ipv4_address(String.to_charlist(host))) ->
        {:ok, address} = :inet.parse_ipv4_address(String.to_charlist(host))
        {:ok, address |> :inet.ntoa() |> List.to_string()}

      true ->
        case Domain.normalize(host) do
          {:ok, domain} -> {:ok, domain.name}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp normalize_port(port_text) do
    case Integer.parse(port_text) do
      {port, ""} when port >= 1 and port <= 65_535 -> {:ok, port}
      _invalid -> {:error, :invalid_port}
    end
  end

  defp validate_rule(%Rule{} = rule) do
    validate_condition(rule) ++ validate_action(rule)
  end

  defp validate_rule(_rule) do
    [Diagnostic.error(:invalid_rule, "PAC rule has an invalid shape")]
  end

  defp validate_condition(%Rule{condition: {:domain_suffix, domain}})
       when is_binary(domain) and domain != "",
       do: []

  defp validate_condition(%Rule{id: id}) do
    [
      Diagnostic.error(:unsupported_condition, "Condition cannot be represented by PAC",
        rule_id: id,
        field: :condition
      )
    ]
  end

  defp validate_action(%Rule{action: action}) when action in [:match, :default], do: []

  defp validate_action(%Rule{id: id}) do
    [
      Diagnostic.error(:unsupported_action, "Action cannot be represented by PAC",
        rule_id: id,
        field: :action
      )
    ]
  end

  defp render_document(rules, proxy_value) do
    direct_domains = domains_for(rules, :default)
    proxy_domains = domains_for(rules, :match)

    [
      "var proxy = 'PROXY #{proxy_value}';",
      render_array("directDomains", direct_domains),
      render_array("proxyDomains", proxy_domains),
      "",
      "function domainMatches(host, domain) {",
      "  return host === domain ||",
      "    (host.length > domain.length &&",
      "      host.slice(-(domain.length + 1)) === '.' + domain);",
      "}",
      "",
      "function anyDomainMatches(host, domains) {",
      "  for (var index = 0; index < domains.length; index += 1) {",
      "    if (domainMatches(host, domains[index])) {",
      "      return true;",
      "    }",
      "  }",
      "",
      "  return false;",
      "}",
      "",
      "function FindProxyForURL(url, host) {",
      "  host = (host || '').toLowerCase();",
      "",
      "  if (anyDomainMatches(host, directDomains)) {",
      "    return 'DIRECT';",
      "  }",
      "",
      "  if (anyDomainMatches(host, proxyDomains)) {",
      "    return proxy;",
      "  }",
      "",
      "  return 'DIRECT';",
      "}"
    ]
    |> List.flatten()
    |> Enum.join("\r\n")
    |> Kernel.<>("\r\n")
  end

  defp domains_for(rules, action) do
    for %Rule{condition: {:domain_suffix, domain}, action: ^action} <- rules, do: domain
  end

  defp render_array(name, []), do: "var #{name} = [];"

  defp render_array(name, domains) do
    last_index = length(domains) - 1

    values =
      domains
      |> Enum.with_index()
      |> Enum.map(fn {domain, index} ->
        comma = if index == last_index, do: "", else: ","
        "  '#{domain}'#{comma}"
      end)

    ["var #{name} = [" | values] ++ ["];"]
  end

  defp invalid_proxy do
    {:error,
     Diagnostic.error(:invalid_proxy, "Proxy must be a valid host and port", field: :proxy)}
  end
end
