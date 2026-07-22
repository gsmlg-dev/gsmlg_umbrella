defmodule GSMLG.ProxyRules.CompilerPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias GSMLG.ProxyRules.Compiler

  @compiled_at ~U[2026-07-23 01:02:03Z]

  property "duplicate-bearing permutations have identical bodies and validators" do
    check all(
            proxy <- StreamData.uniq_list_of(domain(), min_length: 2, max_length: 10),
            direct <- StreamData.uniq_list_of(domain(), min_length: 2, max_length: 10),
            proxy_duplicate_indexes <-
              StreamData.list_of(StreamData.integer(0..(length(proxy) - 1)),
                min_length: 1,
                max_length: 10
              ),
            direct_duplicate_indexes <-
              StreamData.list_of(StreamData.integer(0..(length(direct) - 1)),
                min_length: 1,
                max_length: 10
              ),
            proxy_order <-
              StreamData.list_of(StreamData.integer(),
                length: length(proxy) + length(proxy_duplicate_indexes)
              ),
            direct_order <-
              StreamData.list_of(StreamData.integer(),
                length: length(direct) + length(direct_duplicate_indexes)
              )
          ) do
      options = [generation: 1, compiled_at: @compiled_at, sample_limit: 0]

      proxy_with_duplicates = proxy ++ Enum.map(proxy_duplicate_indexes, &Enum.at(proxy, &1))
      direct_with_duplicates = direct ++ Enum.map(direct_duplicate_indexes, &Enum.at(direct, &1))

      left = input(proxy_with_duplicates, direct_with_duplicates)

      right =
        input(
          permute(proxy_with_duplicates, proxy_order),
          permute(direct_with_duplicates, direct_order)
        )

      assert {:ok, first} = Compiler.compile(left, options)
      assert {:ok, second} = Compiler.compile(right, options)
      assert first.rendered_outputs == second.rendered_outputs
    end
  end

  property "adding a direct child cannot change proxy output" do
    check all(
            proxy <- StreamData.uniq_list_of(domain(), min_length: 1, max_length: 15),
            child_label <- label()
          ) do
      options = [generation: 1, compiled_at: @compiled_at, sample_limit: 0]
      direct_child = "#{child_label}.#{hd(proxy)}"

      assert {:ok, baseline} = Compiler.compile(input(proxy, []), options)
      assert {:ok, changed} = Compiler.compile(input(proxy, [direct_child]), options)
      assert baseline.rendered_outputs.proxy == changed.rendered_outputs.proxy
    end
  end

  defp input(proxy, direct) do
    %{
      remote: Base.encode64(Enum.map_join(proxy, "", &"||#{&1}^\n")),
      local_proxy: "",
      local_direct: Enum.join(direct, "\n")
    }
  end

  defp permute(values, order) do
    permuted =
      values
      |> Enum.zip(order)
      |> Enum.with_index()
      |> Enum.sort_by(fn {{_value, key}, index} -> {key, index} end)
      |> Enum.map(fn {{value, _key}, _index} -> value end)

    if permuted == values, do: tl(values) ++ [hd(values)], else: permuted
  end

  defp domain do
    gen all(labels <- StreamData.list_of(label(), min_length: 2, max_length: 4)) do
      Enum.join(labels, ".")
    end
  end

  defp label do
    StreamData.list_of(StreamData.member_of(Enum.to_list(?a..?z)), min_length: 1, max_length: 8)
    |> StreamData.map(&List.to_string/1)
  end
end
