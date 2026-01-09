defmodule GSMLG.AWS.S3Test do
  use ExUnit.Case, async: false

  alias GSMLG.AWS.S3

  setup do
    # Start Cachex for testing if not already started
    unless Process.whereis(:aws_cache) do
      Cachex.start_link(:aws_cache)
    end

    # Start RateLimiter for testing if not already started
    unless Process.whereis(GSMLG.AWS.RateLimiter) do
      GSMLG.AWS.RateLimiter.start_link()
    end

    # Clear cache before each test
    Cachex.clear(:aws_cache)

    :ok
  end

  describe "S3 module structure" do
    test "exports list_buckets/0" do
      assert function_exported?(S3, :list_buckets, 0)
    end

    test "exports list_objects/1, list_objects/2, list_objects/3" do
      assert function_exported?(S3, :list_objects, 1)
      assert function_exported?(S3, :list_objects, 2)
      assert function_exported?(S3, :list_objects, 3)
    end

    test "exports head_object/2" do
      assert function_exported?(S3, :head_object, 2)
    end

    test "exports get_object/2" do
      assert function_exported?(S3, :get_object, 2)
    end

    test "exports put_object/3 and put_object/4" do
      assert function_exported?(S3, :put_object, 3)
      assert function_exported?(S3, :put_object, 4)
    end

    test "exports delete_object/2" do
      assert function_exported?(S3, :delete_object, 2)
    end
  end

  describe "cache management" do
    test "list_buckets uses cache when populated" do
      # Pre-populate the cache with mock data
      mock_buckets = [%{"Name" => "test-bucket", "CreationDate" => "2024-01-01"}]
      Cachex.put(:aws_cache, "s3 buckets", mock_buckets)

      # Should return cached value without hitting AWS
      result = S3.list_buckets()
      assert result == mock_buckets
    end

    test "cache can be cleared" do
      mock_buckets = [%{"Name" => "test-bucket"}]
      Cachex.put(:aws_cache, "s3 buckets", mock_buckets)

      # Clear and verify
      Cachex.clear(:aws_cache)
      assert {:ok, nil} = Cachex.get(:aws_cache, "s3 buckets")
    end
  end
end
