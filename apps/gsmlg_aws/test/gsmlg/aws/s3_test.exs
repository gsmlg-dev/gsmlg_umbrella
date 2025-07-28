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

  describe "list_buckets" do
    test "returns list of buckets" do
      buckets = S3.list_buckets()
      assert is_list(buckets)
      assert length(buckets) > 1
      assert Enum.any?(buckets, fn bucket -> bucket["Name"] == "gsmlg-test-bucket" end)
    end

    test "caches bucket list" do
      buckets1 = S3.list_buckets()
      buckets2 = S3.list_buckets()
      assert buckets1 == buckets2

      # Verify cache was used
      assert {:ok, ^buckets1} = Cachex.get(:aws_cache, "s3 buckets")
    end
  end

  describe "list_objects" do
    test "returns formatted object list" do
      objects = S3.list_objects("gsmlg-test-bucket")
      assert is_list(objects)
      assert length(objects) == 1

      # Check first object format
      {key, metadata} = List.first(objects)
      assert key == "gtm.txt"
      assert is_map(metadata)
      assert metadata.size == "1244663"
      assert metadata.last_modified == "2025-07-24T14:44:02.000Z"
    end

    test "handles prefix filtering" do
      objects = S3.list_objects("gsmlg-test-bucket", "prefix")
      assert is_list(objects)
    end
  end

  describe "cache management" do
    test "cache is used for subsequent calls" do
      buckets1 = S3.list_buckets()
      buckets2 = S3.list_buckets()
      assert buckets1 == buckets2
    end
  end
end
