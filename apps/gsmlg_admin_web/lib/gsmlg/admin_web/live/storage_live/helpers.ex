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

  def type_icon("image"), do: "image-outline"
  def type_icon("video"), do: "video-outline"
  def type_icon("audio"), do: "music-note-outline"
  def type_icon("document"), do: "file-document-outline"
  def type_icon("pdf"), do: "file-pdf-box"
  def type_icon(_), do: "file-outline"

  def month_name(1), do: "Jan"
  def month_name(2), do: "Feb"
  def month_name(3), do: "Mar"
  def month_name(4), do: "Apr"
  def month_name(5), do: "May"
  def month_name(6), do: "Jun"
  def month_name(7), do: "Jul"
  def month_name(8), do: "Aug"
  def month_name(9), do: "Sep"
  def month_name(10), do: "Oct"
  def month_name(11), do: "Nov"
  def month_name(12), do: "Dec"
end
