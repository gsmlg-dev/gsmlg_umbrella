defmodule GSMLG.ProxyRules.ZeroOmega.ExportTest do
  use ExUnit.Case, async: true

  alias GSMLG.ProxyRules.ZeroOmega.{
    Diagnostic,
    Export,
    Policy,
    RenderedRuleList,
    Rule
  }

  test "normalizes, validates, and renders Switchy with exact metadata" do
    policy = policy([rule("proxy", {:domain_suffix, " Example.COM. "}, :match)])

    assert {:ok, %RenderedRuleList{} = rendered} =
             policy
             |> Export.normalize()
             |> Export.validate_for(:switchy,
               mode: :binary,
               match_profile: "squid",
               default_profile: "direct"
             )
             |> Export.render()

    assert rendered.body == "[SwitchyOmega Conditions]\r\n\r\n*.example.com\r\n"
    assert rendered.content_type == "text/plain; charset=utf-8"
    assert rendered.format == :switchy
    assert rendered.revision == "rev-1"
    assert rendered.checksum == checksum(rendered.body)
    assert rendered.etag == ~s("sha256-#{rendered.checksum}")
    assert rendered.content_length == byte_size(rendered.body)
  end

  test "normalizes PAC proxy options before rendering metadata" do
    policy = policy([rule("proxy", {:domain_suffix, "example.com"}, :match)])

    assert {:ok, %RenderedRuleList{} = first} =
             policy
             |> Export.normalize()
             |> Export.validate_for(:pac, proxy: "PROXY.Example:03128")
             |> Export.render()

    assert {:ok, %RenderedRuleList{} = second} =
             policy
             |> Export.normalize()
             |> Export.validate_for(:pac, proxy: "proxy.example:3128")
             |> Export.render()

    assert first == second
    assert first.format == :pac
    assert first.content_type == "application/x-ns-proxy-autoconfig; charset=utf-8"
    assert first.body =~ "var proxy = 'PROXY proxy.example:3128';\r\n"
    assert first.checksum == checksum(first.body)
  end

  test "normalization diagnostics short-circuit validation and rendering" do
    policy = policy([rule("bad", {:domain_suffix, "not a host"}, :match)])

    assert {:error, [%Diagnostic{code: :invalid_domain}]} =
             policy
             |> Export.normalize()
             |> Export.validate_for(:switchy, [])
             |> Export.render()
  end

  test "format-specific diagnostics short-circuit rendering" do
    policy = policy([rule("cidr", {:cidr, "10.0.0.0/8"}, :match)])

    assert {:error, [%Diagnostic{code: :unsupported_condition, rule_id: "cidr"}]} =
             policy
             |> Export.normalize()
             |> Export.validate_for(:pac, proxy: "proxy.example:3128")
             |> Export.render()

    assert {:error, [%Diagnostic{code: :invalid_proxy, field: :proxy}]} =
             policy([])
             |> Export.normalize()
             |> Export.validate_for(:pac, proxy: "http://proxy.example:3128")
             |> Export.render()
  end

  test "rejects unknown export formats without raising" do
    assert {:error, [%Diagnostic{code: :unsupported_condition}]} =
             policy([])
             |> Export.normalize()
             |> Export.validate_for(:unknown, [])
             |> Export.render()
  end

  defp policy(rules) do
    %Policy{revision: "rev-1", default_action: :default, rules: rules}
  end

  defp rule(id, condition, action) do
    %Rule{
      id: id,
      priority: 1,
      enabled: true,
      condition: condition,
      action: action,
      note: nil,
      input_order: 0
    }
  end

  defp checksum(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
end
