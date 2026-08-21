defmodule GSMLG.ProxyRules.ZeroOmega.NormalizerTest do
  use ExUnit.Case, async: true

  alias GSMLG.ProxyRules.ZeroOmega.{Diagnostic, Normalizer, Policy, Rule}

  test "normalizes enabled rules in stable priority order and removes duplicates" do
    policy =
      policy([
        rule("later", 20, {:domain_suffix, " Example.COM. "}, :match, 0),
        rule("disabled", 1, {:domain_suffix, "disabled.test"}, :default, 1, enabled: false),
        rule("first", 10, {:domain_suffix, "bücher.example"}, :default, 2),
        rule("same-priority", 10, {:domain_suffix, "alpha.example"}, :default, 3),
        rule("duplicate", 20, {:domain_suffix, "example.com"}, :match, 4)
      ])

    assert {:ok, %Policy{rules: normalized}} = Normalizer.normalize_policy(policy)

    assert [
             %Rule{id: "first", condition: {:domain_suffix, "xn--bcher-kva.example"}},
             %Rule{id: "same-priority", condition: {:domain_suffix, "alpha.example"}},
             %Rule{id: "later", condition: {:domain_suffix, "example.com"}, action: :match}
           ] = normalized
  end

  test "normalizes every supported textual condition without changing regex case" do
    policy =
      policy([
        rule("host", 1, {:host_exact, " BÜCHER.example. "}, :match, 0),
        rule("host-glob", 2, {:host_glob, " API-*.Example.COM. "}, :match, 1),
        rule("url-prefix", 3, {:url_prefix, " HTTPS://Example.COM/api/ "}, :match, 2),
        rule("url-glob", 4, {:url_glob, " HTTPS://*.Example.COM/* "}, :match, 3),
        rule("url-regex", 5, {:url_regex, " ^HTTPS://Example\\.COM/ "}, :match, 4),
        rule("cidr", 6, {:cidr, " 10.0.0.0/8 "}, :match, 5),
        rule("keyword", 7, {:keyword, " Example Needle "}, :match, 6)
      ])

    assert {:ok, %Policy{rules: rules}} = Normalizer.normalize_policy(policy)

    assert [
             %Rule{condition: {:host_exact, "xn--bcher-kva.example"}},
             %Rule{condition: {:host_glob, "api-*.example.com"}},
             %Rule{condition: {:url_prefix, "https://example.com/api/"}},
             %Rule{condition: {:url_glob, "https://*.example.com/*"}},
             %Rule{condition: {:url_regex, "^HTTPS://Example\\.COM/"}},
             %Rule{condition: {:cidr, "10.0.0.0/8"}},
             %Rule{condition: {:keyword, "Example Needle"}}
           ] = rules
  end

  test "trims identifiers, notes, and explicit profile actions" do
    policy =
      %Policy{
        revision: " revision-1 ",
        default_action: :default,
        rules: [
          rule(" rule-1 ", 1, {:domain_suffix, "example.com"}, {:profile, " corp "}, 0,
            note: " description "
          )
        ]
      }

    assert {:ok,
            %Policy{
              revision: "revision-1",
              rules: [
                %Rule{id: "rule-1", action: {:profile, "corp"}, note: "description"}
              ]
            }} = Normalizer.normalize_policy(policy)
  end

  test "returns ordered structured diagnostics for invalid rule fields" do
    policy =
      policy([
        rule("bad-note", 1, {:keyword, "ok"}, :default, 0, note: "bad\r\nnote"),
        rule("bad-domain", 2, {:domain_suffix, "not a host"}, :default, 1),
        rule("bad-url", 3, {:url_prefix, "not a url"}, :default, 2),
        rule("bad-regex", 4, {:url_regex, "("}, :default, 3),
        rule("bad-cidr", 5, {:cidr, "10.0.0.0/99"}, :default, 4),
        rule("bad-action", 6, {:keyword, "safe"}, {:profile, "bad+profile"}, 5)
      ])

    assert {:error, diagnostics} = Normalizer.normalize_policy(policy)

    assert [
             %Diagnostic{code: :line_injection, rule_id: "bad-note", field: :note},
             %Diagnostic{code: :invalid_domain, rule_id: "bad-domain", field: :condition},
             %Diagnostic{code: :invalid_url, rule_id: "bad-url", field: :condition},
             %Diagnostic{code: :invalid_regex, rule_id: "bad-regex", field: :condition},
             %Diagnostic{code: :invalid_cidr, rule_id: "bad-cidr", field: :condition},
             %Diagnostic{
               code: :ambiguous_profile_name,
               rule_id: "bad-action",
               field: :action
             }
           ] = diagnostics

    assert Enum.all?(diagnostics, &(&1.severity == :error))
  end

  test "rejects Unicode control and line-separator characters" do
    for value <- ["bad\u0085value", "bad\u2028value", "bad\u2029value"] do
      input = policy([rule("unicode", 1, {:keyword, "safe"}, :match, 0, note: value)])

      assert {:error, [%Diagnostic{code: :line_injection, rule_id: "unicode", field: :note}]} =
               Normalizer.normalize_policy(input)
    end
  end

  test "rejects missing defaults, malformed rules, and unsupported conditions" do
    missing_default = %Policy{revision: "rev", default_action: nil, rules: []}

    assert {:error, [%Diagnostic{code: :missing_default_profile, field: :default_action}]} =
             Normalizer.normalize_policy(missing_default)

    malformed =
      policy([
        rule("unsupported", 1, {:future_condition, "value"}, :match, 0),
        rule("invalid-action", 2, {:keyword, "value"}, :unknown, 1)
      ])

    assert {:error, diagnostics} = Normalizer.normalize_policy(malformed)

    assert [
             %Diagnostic{code: :unsupported_condition, rule_id: "unsupported"},
             %Diagnostic{code: :unsupported_action, rule_id: "invalid-action"}
           ] = diagnostics
  end

  test "normalization is deterministic and idempotent" do
    input =
      policy([
        rule("two", 2, {:domain_suffix, "B.Example."}, :match, 1),
        rule("one", 1, {:domain_suffix, "A.Example."}, :default, 0)
      ])

    assert {:ok, first} = Normalizer.normalize_policy(input)
    assert {:ok, second} = Normalizer.normalize_policy(input)
    assert {:ok, third} = Normalizer.normalize_policy(first)
    assert first == second
    assert first == third
  end

  defp policy(rules) do
    %Policy{revision: "rev-1", default_action: :default, rules: rules}
  end

  defp rule(id, priority, condition, action, input_order, options \\ []) do
    %Rule{
      id: id,
      priority: priority,
      enabled: Keyword.get(options, :enabled, true),
      condition: condition,
      action: action,
      note: Keyword.get(options, :note),
      input_order: input_order
    }
  end
end
