defmodule GSMLG.AWS.S3 do
  require Logger

  @cache_key_s3_buckets "s3 buckets"

  def list_buckets() do
    {:ok, true} = Cachex.exists?(:aws_cache, @cache_key_s3_buckets)
    {:ok, buckets} = Cachex.get(:aws_cache,  @cache_key_s3_buckets )

    buckets
  rescue
    _ ->
      client = get_client()

      buckets =
        case client |> AWS.S3.list_buckets() do
          {:ok,
          %{"ListAllMyBucketsResult" =>
           %{
             "Buckets" => %{"Bucket" => buckets},
             "Owner" => _owner
            }
          }, _resp} ->
            buckets

          {:error, error} ->
            Logger.error("AWS.S3.list_buckets error", error: error)
            []
        end

      {:ok, true} = Cachex.put(:aws_cache, @cache_key_s3_buckets, buckets)

      buckets
  end

  defdelegate get_client(), to: GSMLG.AWS.Client
end
