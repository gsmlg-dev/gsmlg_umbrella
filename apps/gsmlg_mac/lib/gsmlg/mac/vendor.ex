defmodule GSMLG.MAC.Vendor do
  @moduledoc """
  GSMLG.MAC.Vendor provides MAC's manufacturer database.

  """
  alias GSMLG.MAC.Compiler
  alias GSMLG.MAC.Parser

  @source_file Application.app_dir(:gsmlg_mac, "priv") <> "/manuf.txt"

  @mac_lookup_table File.read!(@source_file) |> Compiler.build_lookup_table()

  @doc false
  def mac_lookup_table, do: @mac_lookup_table

  def entries, do: mac_lookup_table() |> Compiler.count_entries()

  @spec lookup(String.t()) :: {:ok, String.t(), String.t()} | :error
  def lookup(mac) when is_binary(mac) do
    {key, bit_mac} =
      case Parser.to_bitstring(mac) do
        <<key::bits-size(24), _::bits-size(24)>> = bit_mac -> {key, bit_mac}
        _ -> {nil, nil}
      end

    case @mac_lookup_table[key] do
      vendor when is_list(vendor) ->
        {:ok, Enum.at(vendor, 0), Enum.at(vendor, 1)}

      {key_bitsize, %{} = sub_match_map} ->
        <<sub_key::bits-size(key_bitsize), _::bits>> = bit_mac

        case sub_match_map[sub_key] do
          vendor when is_list(vendor) -> {:ok, Enum.at(vendor, 0), Enum.at(vendor, 1)}
          _ -> :error
        end

      _ ->
        :error
    end
  end
end
