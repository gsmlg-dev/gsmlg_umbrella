defmodule GSMLG.AWS.S3 do
  require Logger

  @cache_key_s3_buckets "s3 buckets"
  @cache_ttl :timer.minutes(5)

  def list_buckets() do
    case Cachex.get(:aws_cache, @cache_key_s3_buckets) do
      {:ok, buckets} when is_list(buckets) ->
        buckets

      _ ->
        buckets =
          case get_client() |> AWS.S3.list_buckets() do
            {:ok,
             %{
               "ListAllMyBucketsResult" => %{
                 "Buckets" => %{"Bucket" => buckets},
                 "Owner" => _owner
               }
             }, _resp} ->
              buckets

            {:error, error} ->
              Logger.error("AWS.S3.list_buckets error", error: error)
              []
          end

        Cachex.put(:aws_cache, @cache_key_s3_buckets, buckets, ttl: @cache_ttl)
        buckets
    end
  end

  @doc """
  Lists all objects in a bucket.

  ## Parameters
    - bucket_name: The name of the S3 bucket
    - prefix: Optional prefix to filter objects (default: nil)
    - max_keys: Maximum number of keys to return (default: 1000)

  ## Examples
      iex> GSMLG.AWS.S3.list_objects("my-bucket")
      [{"key1", %{"Size" => "1234", "LastModified" => "2023-01-01T00:00:00Z"}}]
  """
  def list_objects(bucket_name, prefix \\ :none, max_keys \\ 1000) do
    case get_client()
         |> AWS.S3.list_objects_v2(bucket_name, %{prefix: prefix, max_keys: max_keys}) do
      {:ok, %{"ListBucketResult" => result}, _resp} ->
        objects =
          case result do
            %{"Contents" => %{"Object" => objects}} -> objects
            %{"Contents" => objects} when is_list(objects) -> objects
            %{"Contents" => object} when is_map(object) -> [object]
            _ -> []
          end

        # Format objects for easier use
        Enum.map(objects, fn obj ->
          {obj["Key"],
           %{
             size: obj["Size"],
             last_modified: obj["LastModified"],
             etag: obj["ETag"],
             storage_class: obj["StorageClass"]
           }}
        end)

      {:error, error} ->
        Logger.error("AWS.S3.list_objects error for bucket #{bucket_name}", error: error)
        []
    end
  end

  @doc """
  Gets an object's metadata without downloading the content.

  ## Examples
      iex> GSMLG.AWS.S3.head_object("my-bucket", "path/to/file.txt")
      {:ok, %{"ContentLength" => "1234", "ContentType" => "text/plain"}}
  """
  def head_object(bucket_name, object_key) do
    case GSMLG.AWS.RateLimiter.S3.with_rate_limit(fn ->
           get_client() |> AWS.S3.head_object(bucket_name, object_key, %{}, [])
         end) do
      {:ok, headers, _resp} ->
        {:ok, headers}

      {:error, :rate_limited} ->
        Logger.error("AWS S3 rate limit exceeded for head_object")
        {:error, :rate_limited}

      {:error, error} ->
        Logger.error("AWS.S3.head_object error for #{bucket_name}/#{object_key}", error: error)
        {:error, error}
    end
  end

  @doc """
  Downloads an object from S3.

  ## Examples
      iex> GSMLG.AWS.S3.get_object("my-bucket", "path/to/file.txt")
      {:ok, "file contents"}
  """
  def get_object(bucket_name, object_key) do
    case GSMLG.AWS.RateLimiter.S3.with_rate_limit(fn ->
           get_client() |> AWS.S3.get_object(bucket_name, object_key)
         end) do
      {:ok, body, _resp} ->
        {:ok, body}

      {:error, :rate_limited} ->
        Logger.error("AWS S3 rate limit exceeded for get_object")
        {:error, :rate_limited}

      {:error, error} ->
        Logger.error("AWS.S3.get_object error for #{bucket_name}/#{object_key}", error: error)
        {:error, error}
    end
  end

  @doc """
  Uploads an object to S3.

  ## Examples
      iex> GSMLG.AWS.S3.put_object("my-bucket", "path/to/file.txt", "file contents")
      :ok
  """
  def put_object(bucket_name, object_key, content, content_type \\ "application/octet-stream") do
    context = %{service: "s3", operation: "put_object", bucket: bucket_name, key: object_key}

    GSMLG.AWS.ErrorHandler.with_error_handling(:put_object, context, fn ->
      GSMLG.AWS.RateLimiter.S3.with_rate_limit(fn ->
        get_client()
        |> AWS.S3.put_object(bucket_name, object_key, content, [{"Content-Type", content_type}])
      end)
    end)
  end

  @doc """
  Deletes an object from S3.

  ## Examples
      iex> GSMLG.AWS.S3.delete_object("my-bucket", "path/to/file.txt")
      :ok
  """
  def delete_object(bucket_name, object_key) do
    case GSMLG.AWS.RateLimiter.S3.with_rate_limit(fn ->
           get_client() |> AWS.S3.delete_object(bucket_name, object_key, %{}, [])
         end) do
      {:ok, _, _resp} ->
        :ok

      {:error, :rate_limited} ->
        Logger.error("AWS S3 rate limit exceeded for delete_object")
        {:error, :rate_limited}

      {:error, error} ->
        Logger.error("AWS.S3.delete_object error for #{bucket_name}/#{object_key}", error: error)
        {:error, error}
    end
  end

  defdelegate get_client(), to: GSMLG.AWS.Client
end
