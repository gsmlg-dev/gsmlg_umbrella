defmodule GSMLG.ProxyRules.ZeroOmega.SwitchyTest do
  use ExUnit.Case, async: true

  alias GSMLG.ProxyRules.ZeroOmega.{Diagnostic, Policy, Rule, Switchy}

  test "renders every canonical condition in binary mode" do
    policy =
      policy([
        rule("suffix", 1, {:domain_suffix, "example.com"}, :match, 0),
        rule("exact", 2, {:host_exact, "exact.example.com"}, :match, 1),
        rule("host-glob", 3, {:host_glob, "api-*.example.com"}, :match, 2),
        rule("url-prefix", 4, {:url_prefix, "https://example.com/api/"}, :match, 3),
        rule("url-prefix-star", 5, {:url_prefix, "https://example.com/static/*"}, :match, 4),
        rule("url-glob", 6, {:url_glob, "https://*.example.com/*"}, :match, 5),
        rule("url-regex", 7, {:url_regex, "^https://example\\.com/"}, :match, 6),
        rule("cidr", 8, {:cidr, "10.0.0.0/8"}, :match, 7),
        rule("keyword", 9, {:keyword, "example"}, :match, 8)
      ])

    assert {:ok, body} = Switchy.render(policy)

    assert body ==
             "[SwitchyOmega Conditions]\r\n\r\n" <>
               "*.example.com\r\n" <>
               "exact.example.com\r\n" <>
               "HostWildcard: api-*.example.com\r\n" <>
               "UrlWildcard: https://example.com/api/*\r\n" <>
               "UrlWildcard: https://example.com/static/*\r\n" <>
               "UrlWildcard: https://*.example.com/*\r\n" <>
               "UrlRegex: ^https://example\\.com/\r\n" <>
               "Ip: 10.0.0.0/8\r\n" <>
               "Keyword: example\r\n"
  end

  test "binary mode preserves rule order, emits notes, and marks default rules" do
    policy =
      policy([
        rule("narrow", 1, {:domain_suffix, "internal.example.com"}, :default, 0,
          note: "Keep internal traffic direct"
        ),
        rule("broad", 2, {:domain_suffix, "example.com"}, :match, 1)
      ])

    assert {:ok, body} = Switchy.render(policy)

    assert body ==
             "[SwitchyOmega Conditions]\r\n\r\n" <>
               "@note Keep internal traffic direct\r\n" <>
               "!*.internal.example.com\r\n" <>
               "*.example.com\r\n"
  end

  test "escapes parser-special leading host globs with an empty condition type" do
    for leading <- ["[", ";", "#", "@", "!", "+"] do
      assert {:ok, body} =
               Switchy.render(
                 policy([rule("special", 1, {:host_glob, leading <> "pattern"}, :match, 0)])
               )

      assert body =~ ": #{leading}pattern\r\n"
    end
  end

  test "matches the binary golden fixture" do
    policy =
      policy([
        rule("direct", 1, {:domain_suffix, "internal.example.com"}, :default, 0),
        rule("google", 2, {:domain_suffix, "google.com"}, :match, 1),
        rule("github", 3, {:domain_suffix, "github.com"}, :match, 2),
        rule("api", 4, {:url_prefix, "https://api.example.net/v1/"}, :match, 3)
      ])

    assert {:ok, body} = Switchy.render(policy)
    assert body == fixture("switchy_binary.txt")
  end

  test "result mode renders explicit profiles and the final default catch-all" do
    policy =
      policy([
        rule("google", 1, {:domain_suffix, "google.com"}, :match, 0),
        rule("corp", 2, {:domain_suffix, "corp.example.com"}, {:profile, "corp-proxy"}, 1),
        rule("internal", 3, {:domain_suffix, "internal.example.com"}, :default, 2)
      ])

    assert {:ok, body} =
             Switchy.render(policy,
               mode: :result,
               match_profile: "squid",
               default_profile: "direct"
             )

    assert body == fixture("switchy_result.txt")
    assert body =~ "*.google.com +squid\r\n"
    assert body =~ "*.corp.example.com +corp-proxy\r\n"
    assert body =~ "!*.internal.example.com\r\n"
    assert String.ends_with?(body, "* +direct\r\n")
  end

  test "binary mode rejects an action outside match and default profiles" do
    policy =
      policy([
        rule("third", 1, {:domain_suffix, "corp.example.com"}, {:profile, "corp-proxy"}, 0)
      ])

    assert {:error, [%Diagnostic{code: :unsupported_action, rule_id: "third", field: :action}]} =
             Switchy.render(policy,
               mode: :binary,
               match_profile: "squid",
               default_profile: "direct"
             )
  end

  test "rejects invalid modes and ambiguous profile options" do
    policy = policy([])

    for options <- [
          [mode: :unknown],
          [match_profile: ""],
          [match_profile: "bad+profile"],
          [default_profile: "bad\nprofile"],
          [default_profile: "bad\u2028profile"],
          [match_profile: "same", default_profile: "same"]
        ] do
      assert {:error, [%Diagnostic{code: :ambiguous_profile_name}]} =
               Switchy.render(policy, options)
    end
  end

  test "uses CRLF exclusively, terminates the file, and is deterministic" do
    policy = policy([rule("one", 1, {:domain_suffix, "example.com"}, :match, 0)])

    assert {:ok, first} = Switchy.render(policy)
    assert {:ok, second} = Switchy.render(policy)
    assert first == second
    assert String.ends_with?(first, "\r\n")

    stripped = String.replace(first, "\r\n", "")
    refute String.contains?(stripped, ["\r", "\n"])
  end

  defp policy(rules) do
    %Policy{revision: "rev-1", default_action: :default, rules: rules}
  end

  defp rule(id, priority, condition, action, input_order, options \\ []) do
    %Rule{
      id: id,
      priority: priority,
      enabled: true,
      condition: condition,
      action: action,
      note: Keyword.get(options, :note),
      input_order: input_order
    }
  end

  defp fixture(name) do
    Path.join([__DIR__, "..", "..", "..", "fixtures", "zero_omega", name])
    |> File.read!()
    |> String.replace("\n", "\r\n")
  end
end
