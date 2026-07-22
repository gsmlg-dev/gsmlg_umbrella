defmodule GSMLG.ProxyRules.HierarchyPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias GSMLG.ProxyRules.{Domain, Hierarchy, Rule}

  property "duplicates and descendants cannot change folded output" do
    check all(prefix <- label()) do
      parent = rule("example.com", 1)
      child = rule("#{prefix}.example.com", 2)

      assert Hierarchy.fold([parent]) == Hierarchy.fold([child, parent, parent])
    end
  end

  property "folded output is independent of input order" do
    check all(domains <- StreamData.uniq_list_of(domain_name(), min_length: 1, max_length: 20)) do
      rules = Enum.with_index(domains, 1) |> Enum.map(fn {name, index} -> rule(name, index) end)

      assert domain_names(Hierarchy.fold(rules)) ==
               domain_names(Hierarchy.fold(Enum.reverse(rules)))
    end
  end

  defp domain_names(rules), do: Enum.map(rules, & &1.domain.name)

  defp domain_name do
    gen all(labels <- StreamData.list_of(label(), min_length: 2, max_length: 4)) do
      Enum.join(labels, ".")
    end
  end

  defp label do
    StreamData.list_of(StreamData.member_of(Enum.to_list(?a..?z)), min_length: 1, max_length: 8)
    |> StreamData.map(&List.to_string/1)
  end

  defp rule(name, location) do
    %Rule{
      domain: %Domain{name: name, reversed_labels: name |> String.split(".") |> Enum.reverse()},
      action: :proxy,
      source: :local_proxy,
      location: location
    }
  end
end
