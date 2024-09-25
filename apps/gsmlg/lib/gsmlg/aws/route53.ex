defmodule GSMLG.AWS.Route53 do
  def list_hosted_zones() do
    access_key_id = System.get_env("AWS_ACCESS_KEY_ID")
    secret_access_key = System.get_env("AWS_SECRET_ACCESS_KEY")
    region = System.get_env("AWS_REGION")
    client = AWS.Client.create(access_key_id, secret_access_key, region)

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
              "NextMarker" => next,
            }
          }, _resp} ->
           {hosted_zones, next}

        {:error, error} ->
          IO.inspect(error)
          {[], nil}
      end

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
    access_key_id = System.get_env("AWS_ACCESS_KEY_ID")
    secret_access_key = System.get_env("AWS_SECRET_ACCESS_KEY")
    region = System.get_env("AWS_REGION")
    client = AWS.Client.create(access_key_id, secret_access_key, region)

    # list_resource_record_sets(client, hosted_zone_id, max_items \\ nil, start_record_identifier \\ nil, start_record_name \\ nil, start_record_type \\ nil, options \\ [])
    {resource_record_sets, next} =
      case client |> AWS.Route53.list_resource_record_sets(hosted_zone_id, nil, nil, start_name, start_type) do
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
          IO.inspect(error)
          {[], nil}
      end

    {resource_record_sets, next}
  end
end
