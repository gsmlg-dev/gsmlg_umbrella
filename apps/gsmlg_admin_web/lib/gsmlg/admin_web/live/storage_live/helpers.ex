defmodule GSMLG.AdminWeb.StorageLive.Helpers do
  @moduledoc """
  Shared helper functions for Storage LiveViews.
  """

  def format_size(nil), do: "—"
  def format_size(0), do: "0 B"

  def format_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  def format_size(_), do: "—"

  def error_to_string(:too_large), do: "File is too large"
  def error_to_string(:too_many_files), do: "Too many files selected"
  def error_to_string(:not_accepted), do: "File type not accepted"
  def error_to_string(err), do: inspect(err)
end
