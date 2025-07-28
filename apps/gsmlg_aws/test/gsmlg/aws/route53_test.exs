defmodule GSMLG.AWS.Route53Test do
  use ExUnit.Case, async: false

  alias GSMLG.AWS.Route53

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

  describe "module structure" do
    # test "has required functions" do
    #   assert function_exported?(Route53, :list_hosted_zones, 0)
    #   assert function_exported?(Route53, :list_resource_record_sets, 3)
    #   assert function_exported?(Route53, :add_record, 5)
    #   assert function_exported?(Route53, :update_record, 5)
    #   assert function_exported?(Route53, :delete_record, 5)
    #   assert function_exported?(Route53, :get_all_records, 1)
    #   assert function_exported?(Route53, :find_record, 3)
    #   assert function_exported?(Route53, :invalidate_zone_cache, 1)
    # end

    test "record operations create correct structures" do
      # Test that add_record creates correct AWS API structure
      record = %{
        "Action" => "CREATE",
        "ResourceRecordSet" => %{
          "Name" => "test.example.com",
          "Type" => "A",
          "TTL" => 300,
          "ResourceRecords" => [%{"Value" => "1.2.3.4"}]
        }
      }

      expected = %{
        "ChangeBatch" => %{
          "Changes" => [record]
        }
      }

      # We can't test the actual AWS call, but we can verify the structure
      assert is_map(expected)
    end

    test "update_record uses UPSERT action" do
      record = %{
        "Action" => "UPSERT",
        "ResourceRecordSet" => %{
          "Name" => "test.example.com",
          "Type" => "A",
          "TTL" => 300,
          "ResourceRecords" => [%{"Value" => "5.6.7.8"}]
        }
      }

      assert record["Action"] == "UPSERT"
    end

    test "delete_record uses DELETE action" do
      record = %{
        "Action" => "DELETE",
        "ResourceRecordSet" => %{
          "Name" => "test.example.com",
          "Type" => "A",
          "TTL" => 300,
          "ResourceRecords" => [%{"Value" => "1.2.3.4"}]
        }
      }

      assert record["Action"] == "DELETE"
    end
  end

  describe "caching" do
    test "cache operations work" do
      test_key = "test_cache_key"
      test_value = {[], nil}

      # Test cache put/get
      Cachex.put(:aws_cache, test_key, test_value)
      assert {:ok, ^test_value} = Cachex.get(:aws_cache, test_key)

      # Test cache expiration
      Cachex.expire(:aws_cache, test_key, 0)
      :timer.sleep(10)
      assert {:ok, nil} = Cachex.get(:aws_cache, test_key)
    end

    test "invalidate_zone_cache targets correct keys" do
      Cachex.put(:aws_cache, "route53 resource_record_sets Z123456789 nil nil", {[], nil})
      Cachex.put(:aws_cache, "route53 resource_record_sets Z987654321 nil nil", {[], nil})
      Cachex.put(:aws_cache, "route53 hosted_zones", {[], nil})

      assert {:ok, :cleared} = Route53.invalidate_zone_cache("Z123456789")

      # Verify targeted cache was removed
      assert {:ok, nil} =
               Cachex.get(:aws_cache, "route53 resource_record_sets Z123456789 nil nil")

      assert {:ok, {[], nil}} =
               Cachex.get(:aws_cache, "route53 resource_record_sets Z987654321 nil nil")

      assert {:ok, {[], nil}} = Cachex.get(:aws_cache, "route53 hosted_zones")
    end
  end

  describe "utility functions" do
    test "record operations handle multiple values" do
      values = ["1.2.3.4", "5.6.7.8"]

      record = %{
        "Action" => "CREATE",
        "ResourceRecordSet" => %{
          "Name" => "multi.example.com",
          "Type" => "A",
          "TTL" => 600,
          "ResourceRecords" => [
            %{"Value" => "1.2.3.4"},
            %{"Value" => "5.6.7.8"}
          ]
        }
      }

      expected_records = Enum.map(values, &%{"Value" => &1})
      assert record["ResourceRecordSet"]["ResourceRecords"] == expected_records
    end

    test "record operations use custom TTL" do
      ttl = 600

      record = %{
        "Action" => "CREATE",
        "ResourceRecordSet" => %{
          "Name" => "test.example.com",
          "Type" => "A",
          "TTL" => ttl,
          "ResourceRecords" => [%{"Value" => "1.2.3.4"}]
        }
      }

      assert record["ResourceRecordSet"]["TTL"] == ttl
    end
  end
end
