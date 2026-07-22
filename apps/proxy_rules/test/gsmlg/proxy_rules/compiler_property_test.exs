defmodule GSMLG.ProxyRules.CompilerPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias GSMLG.ProxyRules.Compiler

  @compiled_at ~U[2026-07-23 01:02:03Z]

  property "shuffled equivalent inputs have identical outputs and validators" do
    check all(
            proxy <- StreamData.uniq_list_of(domain(), min_length: 1, max_length: 15),
            direct <- StreamData.uniq_list_of(domain(), max_length: 15)
          ) do
      options = [generation: 1, compiled_at: @compiled_at, sample_limit: 0]

      left = input(proxy, direct)
      right = input(Enum.reverse(proxy), Enum.reverse(direct))

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
