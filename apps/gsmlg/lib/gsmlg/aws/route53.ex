defmodule GSMLG.AWS.Route53 do
  require Logger

  def list_hosted_zones() do
    {:ok, true} = Cachex.exists?(:aws_cache, "route53 hosted_zones")
    {:ok, {hosted_zones, next}} = Cachex.get(:aws_cache, "route53 hosted_zones")

    {hosted_zones, next}
  rescue
    _ ->
      client = get_client()

      {hosted_zones, next} =
        case client |> AWS.Route53.list_hosted_zones(nil, nil, nil, 10) do
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

      {:ok, true} = Cachex.put(:aws_cache, "route53 hosted_zones", {hosted_zones, next})

      {hosted_zones, next}
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
    {:ok, _, _} =
      get_client() |> AWS.Route53.change_resource_record_sets(hosted_zone_id, input, options)

    {:ok, key_list} = Cachex.keys(:aws_cache)

    key_list
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

    :ok
  end

  defdelegate get_client(), to: GSMLG.AWS.Client
end
