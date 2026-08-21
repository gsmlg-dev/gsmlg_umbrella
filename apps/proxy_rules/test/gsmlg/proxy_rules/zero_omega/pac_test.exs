defmodule GSMLG.ProxyRules.ZeroOmega.PACTest do
  use ExUnit.Case, async: true

  alias GSMLG.ProxyRules.ZeroOmega.{Diagnostic, PAC, Policy, Rule}

  test "normalizes supported DNS, IPv4, and bracketed IPv6 proxy endpoints" do
    for {input, expected} <- [
          {"Proxy.Example.COM:3128", "proxy.example.com:3128"},
          {"10.100.0.1:1", "10.100.0.1:1"},
          {"10.100.0.1:65535", "10.100.0.1:65535"},
          {"[2001:0DB8:0:0:0:0:0:1]:8080", "[2001:db8::1]:8080"}
        ] do
      assert {:ok, ^expected} = PAC.normalize_proxy(input)
    end
  end

  test "rejects malformed or injectable proxy endpoints" do
    for input <- [
          "",
          "proxy.example.com",
          "proxy.example.com:0",
          "proxy.example.com:65536",
          "proxy.example.com:not-a-port",
          "http://proxy.example.com:3128",
          "user@proxy.example.com:3128",
          "proxy.example.com:3128/path",
          "proxy.example.com:3128?query=1",
          "proxy example.com:3128",
          "proxy.example.com: 3128",
          "proxy.example.com:'3128",
          "proxy.example.com:\\3128",
          "proxy.example.com:3128\r\nDIRECT",
          <<"proxy.example.com:3128", 0>>,
          "[2001:db8::1:3128"
        ] do
      assert {:error, %Diagnostic{code: :invalid_proxy, field: :proxy}} =
               PAC.normalize_proxy(input)
    end
  end

  test "renders direct domains before proxy domains and matches the golden fixture" do
    policy =
      policy([
        rule("google", 2, "google.com", :match, 1),
        rule("internal", 1, "internal.example.com", :default, 0),
        rule("github", 3, "github.com", :match, 2)
      ])

    assert {:ok, body} = PAC.render(policy, proxy: "10.100.0.1:3128")

    assert body == fixture("proxy.pac")
    assert body =~ "var proxy = 'PROXY 10.100.0.1:3128';\r\n"
    assert index(body, "internal.example.com") < index(body, "google.com")
    assert index(body, "google.com") < index(body, "github.com")
    assert body =~ "return 'DIRECT';"
    assert body =~ "return proxy;"
  end

  test "emits an explicit DNS label-boundary matcher" do
    assert {:ok, body} =
             PAC.render(policy([rule("domain", 1, "example.com", :match, 0)]),
               proxy: "proxy.example:3128"
             )

    assert body =~ "host === domain"
    assert body =~ "host.length > domain.length"
    assert body =~ "host.slice(-(domain.length + 1)) === '.' + domain"
    refute body =~ "host.endsWith(domain)"
  end

  test "rejects conditions and actions that PAC cannot represent" do
    unsupported_condition =
      %Policy{
        revision: "rev-1",
        default_action: :default,
        rules: [
          %Rule{
            id: "cidr",
            priority: 1,
            enabled: true,
            condition: {:cidr, "10.0.0.0/8"},
            action: :match,
            input_order: 0
          }
        ]
      }

    assert {:error,
            [%Diagnostic{code: :unsupported_condition, rule_id: "cidr", field: :condition}]} =
             PAC.validate_policy(unsupported_condition)

    unsupported_action =
      policy([rule("corp", 1, "corp.example.com", {:profile, "corp-proxy"}, 0)])

    assert {:error, [%Diagnostic{code: :unsupported_action, rule_id: "corp", field: :action}]} =
             PAC.validate_policy(unsupported_action)
  end

  test "uses CRLF exclusively, terminates the file, and is deterministic" do
    policy = policy([rule("one", 1, "example.com", :match, 0)])

    assert {:ok, first} = PAC.render(policy, proxy: "PROXY.EXAMPLE:3128")
    assert {:ok, second} = PAC.render(policy, proxy: "proxy.example:3128")
    assert first == second
    assert String.ends_with?(first, "\r\n")

    stripped = String.replace(first, "\r\n", "")
    refute String.contains?(stripped, ["\r", "\n"])
  end

  test "renders valid empty policies without inventing proxy rules" do
    assert {:ok, body} = PAC.render(policy([]), proxy: "proxy.example:3128")
    assert body =~ "var directDomains = [];\r\n"
    assert body =~ "var proxyDomains = [];\r\n"
    assert String.ends_with?(body, "\r\n")
  end

  defp policy(rules) do
    %Policy{revision: "rev-1", default_action: :default, rules: rules}
  end

  defp rule(id, priority, domain, action, input_order) do
    %Rule{
      id: id,
      priority: priority,
      enabled: true,
      condition: {:domain_suffix, domain},
      action: action,
      note: nil,
      input_order: input_order
    }
  end

  defp fixture(name) do
    Path.join([__DIR__, "..", "..", "..", "fixtures", "zero_omega", name])
    |> File.read!()
    |> String.replace("\n", "\r\n")
  end

  defp index(body, value) do
    {index, _length} = :binary.match(body, value)
    index
  end
end
