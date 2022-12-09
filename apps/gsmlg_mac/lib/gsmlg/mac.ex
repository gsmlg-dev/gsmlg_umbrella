defmodule GSMLG.MAC do
  @moduledoc """
  GSMLG.MAC provides a suit of MAC tools.

  """

  @doc """
  Lookup manufacturer of MAC.

  if found, return {:ok, "short name", "full information"}
  if not found, return :error

  ## Examples

      iex> GSMLG.MAC.lookup_vendor("00:00:0A:BB:28:FC")
      {:ok, "OmronTat", "Omron Tateisi Electronics Co."}

  """
  @spec lookup_vendor(String.t()) :: {:ok, String.t(), String.t()} | :error
  defdelegate lookup_vendor(mac), to: GSMLG.MAC.Vendor, as: :lookup
end
