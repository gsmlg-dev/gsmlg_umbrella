defmodule GSMLG.ProxyRules.ZeroOmega.PublishedPolicyTest do
  use ExUnit.Case, async: true

  alias GSMLG.ProxyRules.ZeroOmega.{Policy, PublishedPolicy, Rule}

  test "encodes domain partitions compactly and expands one canonical policy" do
    published =
      PublishedPolicy.new(
        "42",
        ["internal.example.com"],
        ["google.com", "github.com"]
      )

    assert %PublishedPolicy{
             revision: "42",
             direct_domains: "internal.example.com\n",
             proxy_domains: "google.com\ngithub.com\n"
           } = published

    assert {:ok,
            %Policy{
              revision: "42",
              default_action: :default,
              rules: [
                %Rule{condition: {:domain_suffix, "internal.example.com"}, action: :default},
                %Rule{condition: {:domain_suffix, "google.com"}, action: :match},
                %Rule{condition: {:domain_suffix, "github.com"}, action: :match}
              ]
            }} = PublishedPolicy.to_policy(published)
  end

  test "represents empty partitions as empty reference-counted binaries" do
    published = PublishedPolicy.new("0", [], [])
    assert published.direct_domains == ""
    assert published.proxy_domains == ""
    assert {:ok, %Policy{rules: []}} = PublishedPolicy.to_policy(published)
  end
end
