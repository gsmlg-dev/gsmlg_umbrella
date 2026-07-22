defmodule GSMLG.ProxyRules.RendererTest do
  use ExUnit.Case, async: true

  alias GSMLG.ProxyRules.{Domain, Renderer, Rule}

  test "renders every format in lexicographic order with one trailing newline" do
    rules = rules(~w(google.com example.com))

    assert Renderer.render(rules, :raw) == "example.com\ngoogle.com\n"
    assert Renderer.render(rules, :squid) == ".example.com\n.google.com\n"

    assert Renderer.render(rules, :clash) ==
             "DOMAIN-SUFFIX,example.com\nDOMAIN-SUFFIX,google.com\n"
  end

  test "renders an empty list as an empty binary" do
    assert Renderer.render([], :raw) == ""
    assert Renderer.render([], :squid) == ""
    assert Renderer.render([], :clash) == ""
  end

  defp rules(domains) do
    domains
    |> Enum.with_index(1)
    |> Enum.map(fn {name, location} ->
      %Rule{
        domain: %Domain{name: name, reversed_labels: name |> String.split(".") |> Enum.reverse()},
        action: :proxy,
        source: :local_proxy,
        location: location
      }
    end)
  end
end
