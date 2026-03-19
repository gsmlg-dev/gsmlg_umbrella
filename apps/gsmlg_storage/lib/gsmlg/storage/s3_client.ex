defmodule GSMLG.Storage.S3Client do
  @moduledoc """
  S3 client wrapper for storage operations.
  Delegates to GSMLG.AWS.S3 with storage-specific defaults.
  """

  require Logger

  @doc """
  Uploads an object to S3.
  Returns `:ok` or `{:error, reason}`.
  """
  def put_object(bucket, key, data, content_type) do
    case GSMLG.AWS.S3.put_object(bucket, key, data, content_type) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  Gets an object from S3.
  Returns `{:ok, binary}` or `{:error, reason}`.
  """
  def get_object(bucket, key) do
    GSMLG.AWS.S3.get_object(bucket, key)
  end

  @doc """
  Deletes an object from S3.
  Returns `:ok` or `{:error, reason}`.
  """
  def delete_object(bucket, key) do
    case GSMLG.AWS.S3.delete_object(bucket, key) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to delete S3 object #{bucket}/#{key}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
