defmodule GSMLG.MAC.CompilerTest do
  use ExUnit.Case, async: true

  alias GSMLG.MAC.Compiler
  alias GSMLG.MAC.Parser
  alias GSMLG.MAC.Vendor

  @broad "00:11:22\tBroad\tBroad Vendor"
  @medium "00:11:22:30:00:00/28\tMedium\tMedium Vendor"
  @precise "00:11:22:33:40:00/36\tPrecise\tPrecise Vendor"

  test "preserves mixed prefix lengths regardless of database order" do
    tables =
      for lines <- permutations([@broad, @medium, @precise]) do
        table = Compiler.build_lookup_table(Enum.join(lines, "\n"))
        assert Compiler.count_entries(table) == 3
        table
      end

    assert Enum.uniq(tables) |> length() == 1
  end

  test "preserves mixed longer prefixes without a /24 entry" do
    for lines <- [[@medium, @precise], [@precise, @medium]] do
      table = Compiler.build_lookup_table(Enum.join(lines, "\n"))
      assert Compiler.count_entries(table) == 2
    end
  end

  test "looks up the longest matching prefix and falls back to broader vendors" do
    for lines <- permutations([@broad, @medium, @precise]) do
      table = Compiler.build_lookup_table(Enum.join(lines, "\n"))

      assert Vendor.lookup("00:11:22:33:4F:FF", table) == {:ok, "Precise", "Precise Vendor"}
      assert Vendor.lookup("00-11-22-33-50-00", table) == {:ok, "Medium", "Medium Vendor"}
      assert Vendor.lookup("0011.2240.0000", table) == {:ok, "Broad", "Broad Vendor"}
      assert Vendor.lookup("001122334000", table) == {:ok, "Precise", "Precise Vendor"}
      assert Vendor.lookup("AA:BB:CC:00:00:00", table) == :error
      assert Vendor.lookup("00:11:22", table) == :error
      assert Vendor.lookup("invalid", table) == :error
    end
  end

  test "returns an error when no longer prefix matches and no /24 fallback exists" do
    table = Compiler.build_lookup_table(Enum.join([@medium, @precise], "\n"))

    assert Vendor.lookup("00:11:22:33:40:00", table) == {:ok, "Precise", "Precise Vendor"}
    assert Vendor.lookup("00:11:22:3F:FF:FF", table) == {:ok, "Medium", "Medium Vendor"}
    assert Vendor.lookup("00:11:22:40:00:00", table) == :error
  end

  test "keeps the existing table format for a single width per OUI" do
    key = Parser.to_bitstring("00:11:22")
    prefix = Parser.to_bitstring("00:11:22:30:00:00/28")

    assert Compiler.build_lookup_table(@broad) == %{key => ["Broad", "Broad Vendor"]}

    assert Compiler.build_lookup_table(@medium) ==
             %{key => {28, %{prefix => ["Medium", "Medium Vendor"]}}}

    assert Vendor.lookup("00:11:22:3F:FF:FF", Compiler.build_lookup_table(@medium)) ==
             {:ok, "Medium", "Medium Vendor"}

    assert Vendor.lookup("00:11:22:40:00:00", Compiler.build_lookup_table(@medium)) == :error
  end

  test "retains multiple vendors of the same width alongside mixed widths" do
    sibling = "00:11:22:33:50:00/36\tSibling\tSibling Vendor"
    table = Compiler.build_lookup_table(Enum.join([@broad, @medium, @precise, sibling], "\n"))

    assert Compiler.count_entries(table) == 4
    assert Vendor.lookup("00:11:22:33:5F:FF", table) == {:ok, "Sibling", "Sibling Vendor"}
    assert Vendor.lookup("00:11:22:33:4F:FF", table) == {:ok, "Precise", "Precise Vendor"}
  end

  test "ignores comments and prefixes shorter than /24" do
    table = Compiler.build_lookup_table("# ignored\n00:11:00:00:00:00/16\tIgnored\n" <> @broad)

    assert Compiler.count_entries(table) == 1
    assert Vendor.lookup("00:11:22:00:00:00", table) == {:ok, "Broad", "Broad Vendor"}
  end

  defp permutations([]), do: [[]]

  defp permutations(lines) do
    for line <- lines, rest <- permutations(List.delete(lines, line)), do: [line | rest]
  end
end
