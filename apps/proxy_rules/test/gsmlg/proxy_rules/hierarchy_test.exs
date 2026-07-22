defmodule GSMLG.ProxyRules.HierarchyTest do
  use ExUnit.Case, async: true

  alias GSMLG.ProxyRules.{Domain, Hierarchy, Rule}

  test "folds descendants only within one supplied list" do
    rules = rules(~w(example.com api.example.com other.org), :proxy)

    assert ["example.com", "other.org"] ==
             rules |> Hierarchy.fold() |> Enum.map(& &1.domain.name)
  end

  test "deduplicates exact domains and reports duplicates separately from descendants" do
    rules =
      rules(
        ~w(api.example.com example.com example.com deep.api.example.com other.org other.org),
        :proxy
      )

    assert %{
             rules: folded,
             duplicate_count: 2,
             collapsed_count: 2
           } = Hierarchy.fold_with_stats(rules)

    assert Enum.map(folded, & &1.domain.name) == ["example.com", "other.org"]
  end

  test "returns deterministic lexicographic order and retains the first exact duplicate" do
    first = rule("z.example", :direct, 7)
    duplicate = rule("z.example", :direct, 9)
    rules = [rule("beta.test", :direct, 3), duplicate, rule("alpha.test", :direct, 2), first]

    assert [alpha, beta, zed] = Hierarchy.fold(rules)
    assert Enum.map([alpha, beta, zed], & &1.domain.name) == ~w(alpha.test beta.test z.example)
    assert zed.location == 9
  end

  test "folds a large set by comparing each descendant with its adjacent retained parent" do
    parents = for index <- 1..2_000, do: "root-#{index}.test"
    descendants = Enum.map(parents, &"www.#{&1}")

    folded =
      (descendants ++ parents)
      |> rules(:proxy)
      |> Hierarchy.fold()

    assert Enum.map(folded, & &1.domain.name) == Enum.sort(parents)
  end

  defp rules(domains, action) do
    domains
    |> Enum.with_index(1)
    |> Enum.map(fn {domain, location} -> rule(domain, action, location) end)
  end

  defp rule(name, action, location) do
    %Rule{
      domain: %Domain{name: name, reversed_labels: name |> String.split(".") |> Enum.reverse()},
      action: action,
      source: :local_proxy,
      location: location
    }
  end
end
