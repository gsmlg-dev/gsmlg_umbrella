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

  def parent_prefix(prefix) do
    prefix
    |> String.trim_trailing("/")
    |> String.split("/")
    |> Enum.drop(-1)
    |> Enum.map_join("", &(&1 <> "/"))
  end

  def storage_error(:session_not_found), do: "Session expired. Please sign in again."
  def storage_error(:backend_changed), do: "S3 configuration changed. Refresh the listing."
  def storage_error(:missing_s3_access_key_id), do: "S3 access key is missing."
  def storage_error(:missing_s3_secret_access_key), do: "S3 secret key is missing."
  def storage_error(_reason), do: "Could not read the file listing from S3. Try refreshing."

  def mutation_error(:backend_changed), do: storage_error(:backend_changed)
  def mutation_error(:file_referenced), do: "This file is still used by a note or sync reader."
  def mutation_error(:invalid_prefix), do: "Enter a valid folder path."
  def mutation_error(%Ecto.Changeset{}), do: "Enter a valid tenant and file type."
  def mutation_error(_reason), do: "Could not change the S3 object. Try again."

  def folder_mutation_error(:file_referenced),
    do: "This folder contains a file still used by a note or sync reader."

  def folder_mutation_error(:file_processing),
    do: "An upload in this folder is still processing. Try again after it finishes."

  def folder_mutation_error(:folder_exists), do: "A folder with this name already exists."

  def folder_mutation_error(:folder_not_found),
    do: "This folder no longer exists. Refresh the listing."

  def folder_mutation_error(:folder_changed),
    do: "The folder changed during this operation. Refresh the listing and try again."

  def folder_mutation_error(:invalid_folder_name),
    do: "Enter a folder name without / or control characters."

  def folder_mutation_error(reason)
      when reason in [:invalid_folder_prefix, :reserved_storage_key],
      do: "This folder path cannot be changed."

  def folder_mutation_error(:object_key_conflict),
    do: "An object with this name already exists. Refresh the listing."

  def folder_mutation_error({:folder_operation_failed, _stage, _key, _reason}),
    do: "The operation stopped partway. Refresh the listing to check the remaining files."

  def folder_mutation_error(:folder_operation_failed),
    do: "The operation could not finish. Refresh the listing to check the remaining files."

  def folder_mutation_error(reason), do: mutation_error(reason)

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
