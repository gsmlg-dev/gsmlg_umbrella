defmodule GSMLG.AWS.Route53 do
  require Logger

  @cache_ttl :timer.minutes(5)

  def list_hosted_zones() do
    case Cachex.get(:aws_cache, "route53 hosted_zones") do
      {:ok, {hosted_zones, next}} ->
        {hosted_zones, next}

      _ ->
        client = get_client()

        {hosted_zones, next} =
          case client |> AWS.Route53.list_hosted_zones(nil, nil, nil, 100) do
            {:ok,
             %{
               "ListHostedZonesResponse" => %{
                 "HostedZones" => %{"HostedZone" => hosted_zones},
                 "IsTruncated" => "false",
                 "MaxItems" => _max_items
               }
             }, _resp} ->
              {hosted_zones, nil}

            {:ok,
             %{
               "ListHostedZonesResponse" => %{
                 "HostedZones" => %{"HostedZone" => hosted_zones},
                 "IsTruncated" => "true",
                 "MaxItems" => _max_items,
                 "NextMarker" => next
               }
             }, _resp} ->
              {hosted_zones, next}

            {:error, error} ->
              Logger.error("AWS.Route53.list_hosted_zones error", error: error)
              {[], nil}
          end

        Cachex.put(:aws_cache, "route53 hosted_zones", {hosted_zones, next}, ttl: @cache_ttl)
        {hosted_zones, next}
    end
  end

  @doc """

  ```
  [
    %{
      "Name" => "gsmlg.app.",
      "ResourceRecords" => %{
        "ResourceRecord" => [
          %{"Value" => "ns-1242.awsdns-27.org."},
          %{"Value" => "ns-895.awsdns-47.net."},
          %{"Value" => "ns-159.awsdns-19.com."},
          %{"Value" => "ns-1741.awsdns-25.co.uk."}
        ]
      },
      "TTL" => "172800",
      "Type" => "NS"
    },
    %{
      "Name" => "gsmlg.app.",
      "ResourceRecords" => %{
        "ResourceRecord" => %{
          "Value" => "ns-1242.awsdns-27.org. awsdns-hostmaster.amazon.com. 1 3600 900 1209600 120"
        }
      },
      "TTL" => "900",
      "Type" => "SOA"
    },
  ]
  ```
  """
  def list_resource_record_sets(hosted_zone_id, start_name \\ nil, start_type \\ nil) do
    cache_key = "route53 resource_record_sets " <> "#{hosted_zone_id} #{start_name} #{start_type}"

    {:ok, true} = Cachex.exists?(:aws_cache, cache_key)
    {:ok, {resource_record_sets, next}} = Cachex.get(:aws_cache, cache_key)

    {resource_record_sets, next}
  rescue
    _ ->
      client = get_client()

      # list_resource_record_sets(client, hosted_zone_id, max_items \\ nil, start_record_identifier \\ nil, start_record_name \\ nil, start_record_type \\ nil, options \\ [])
      {resource_record_sets, next} =
        case client
             |> AWS.Route53.list_resource_record_sets(
               hosted_zone_id,
               nil,
               nil,
               start_name,
               start_type
             ) do
          {:ok,
           %{
             "ListResourceRecordSetsResponse" => %{
               "ResourceRecordSets" => %{"ResourceRecordSet" => resource_record_sets},
               "IsTruncated" => "false",
               "MaxItems" => _max_items
             }
           }, _resp} ->
            {resource_record_sets, nil}

          {:ok,
           %{
             "ListResourceRecordSetsResponse" => %{
               "ResourceRecordSets" => %{"ResourceRecordSet" => resource_record_sets},
               "IsTruncated" => "true",
               "MaxItems" => _max_items,
               "NextRecordName" => next_record_name,
               "NextRecordType" => next_record_type
             }
           }, _resp} ->
            {resource_record_sets, {next_record_name, next_record_type}}

          {:error, error} ->
            Logger.error("AWS.Route53.list_resource_record_sets error", error: error)
            {[], nil}
        end

      cache_key =
        "route53 resource_record_sets " <> "#{hosted_zone_id} #{start_name} #{start_type}"

      {:ok, true} = Cachex.put(:aws_cache, cache_key, {resource_record_sets, next})

      {resource_record_sets, next}
  end

  def change_resource_record_sets(hosted_zone_id, input, options \\ []) do
    case get_client()
         |> AWS.Route53.change_resource_record_sets(hosted_zone_id, input, options) do
      {:ok, _, _} ->
        invalidate_zone_cache(hosted_zone_id)
        :ok

      {:error, error} ->
        Logger.error("AWS.Route53.change_resource_record_sets error", error: error)
        {:error, error}

      error ->
        Logger.error("AWS.Route53.change_resource_record_sets unexpected error", error: error)
        {:error, :unexpected_error}
    end
  end

  @doc """
  Adds a single DNS record to a hosted zone.

  ## Parameters
    - hosted_zone_id: The ID of the hosted zone
    - name: The DNS name for the record
    - type: The DNS record type (A, AAAA, CNAME, MX, TXT, etc.)
    - values: List of values for the record
    - ttl: Time to live in seconds (default: 300)

  ## Examples
      iex> GSMLG.AWS.Route53.add_record("Z123456789", "www.example.com", "A", ["1.2.3.4"])
      :ok
  """
  def add_record(hosted_zone_id, name, type, values, ttl \\ 300) do
    record = %{
      "Action" => "CREATE",
      "ResourceRecordSet" => %{
        "Name" => name,
        "Type" => type,
        "TTL" => ttl,
        "ResourceRecords" => Enum.map(values, &%{"Value" => &1})
      }
    }

    change_resource_record_sets(hosted_zone_id, %{"ChangeBatch" => %{"Changes" => [record]}})
  end

  @doc """
  Updates an existing DNS record in a hosted zone.

  ## Examples
      iex> GSMLG.AWS.Route53.update_record("Z123456789", "www.example.com", "A", ["5.6.7.8"])
      :ok
  """
  def update_record(hosted_zone_id, name, type, values, ttl \\ 300) do
    record = %{
      "Action" => "UPSERT",
      "ResourceRecordSet" => %{
        "Name" => name,
        "Type" => type,
        "TTL" => ttl,
        "ResourceRecords" => Enum.map(values, &%{"Value" => &1})
      }
    }

    change_resource_record_sets(hosted_zone_id, %{"ChangeBatch" => %{"Changes" => [record]}})
  end

  @doc """
  Deletes a DNS record from a hosted zone.

  ## Examples
      iex> GSMLG.AWS.Route53.delete_record("Z123456789", "www.example.com", "A", ["1.2.3.4"])
      :ok
  """
  def delete_record(hosted_zone_id, name, type, values, ttl \\ 300) do
    record = %{
      "Action" => "DELETE",
      "ResourceRecordSet" => %{
        "Name" => name,
        "Type" => type,
        "TTL" => ttl,
        "ResourceRecords" => Enum.map(values, &%{"Value" => &1})
      }
    }

    change_resource_record_sets(hosted_zone_id, %{"ChangeBatch" => %{"Changes" => [record]}})
  end

  @doc """
  Gets all records for a hosted zone with auto-pagination.
  """
  def get_all_records(hosted_zone_id) do
    get_all_records(hosted_zone_id, nil, nil, [])
  end

  defp get_all_records(hosted_zone_id, start_name, start_type, acc) do
    {records, next} = list_resource_record_sets(hosted_zone_id, start_name, start_type)

    case next do
      nil ->
        {:ok, acc ++ records}

      {next_name, next_type} ->
        get_all_records(hosted_zone_id, next_name, next_type, acc ++ records)
    end
  end

  @doc """
  Finds a specific DNS record by name and type.
  """
  def find_record(hosted_zone_id, name, type) do
    case list_resource_record_sets(hosted_zone_id) do
      {records, _} ->
        record = Enum.find(records, &(&1["Name"] == name and &1["Type"] == type))
        {:ok, record}

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Clears all cached Route53 data for a specific zone.
  """
  def invalidate_zone_cache(hosted_zone_id) do
    case Cachex.keys(:aws_cache) do
      {:ok, keys} ->
        keys
        |> Enum.each(fn key ->
          case key do
            "route53 resource_record_sets " <> zone_info ->
              if String.starts_with?(zone_info, "#{hosted_zone_id}") do
                Cachex.del(:aws_cache, key)
              end

            _ ->
              nil
          end
        end)

        {:ok, :cleared}

      _ ->
        {:error, :cache_error}
    end
  end

  defdelegate get_client(), to: GSMLG.AWS.Client
end
