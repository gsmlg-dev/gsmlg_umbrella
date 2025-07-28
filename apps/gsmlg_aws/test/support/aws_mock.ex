defmodule GSMLG.AWS.Mock do
  @moduledoc """
  Mock AWS Route53 functions for testing that properly implements the AWS SDK interface.
  """

  def list_hosted_zones(_client, _marker, _max_items, _delegation_set_id, _max_items2) do
    {:ok,
     %{
       "ListHostedZonesResponse" => %{
         "HostedZones" => %{
           "HostedZone" => [
             %{
               "Id" => "/hostedzone/Z123456789",
               "Name" => "example.com.",
               "CallerReference" => "test-ref-123",
               "Config" => %{"PrivateZone" => false, "Comment" => "Test zone"},
               "ResourceRecordSetCount" => 4
             }
           ]
         },
         "IsTruncated" => "false",
         "MaxItems" => "100"
       }
     }, %{}}
  end

  def list_resource_record_sets(
        _client,
        _hosted_zone_id,
        _max_items,
        _start_record_identifier,
        _start_record_name,
        _start_record_type,
        _options
      ) do
    {:ok,
     %{
       "ListResourceRecordSetsResponse" => %{
         "ResourceRecordSets" => %{
           "ResourceRecordSet" => [
             %{
               "Name" => "example.com.",
               "Type" => "A",
               "TTL" => "300",
               "ResourceRecords" => %{
                 "ResourceRecord" => [%{"Value" => "1.2.3.4"}]
               }
             },
             %{
               "Name" => "www.example.com.",
               "Type" => "CNAME",
               "TTL" => "300",
               "ResourceRecords" => %{
                 "ResourceRecord" => [%{"Value" => "example.com"}]
               }
             }
           ]
         },
         "IsTruncated" => "false",
         "MaxItems" => "100"
       }
     }, %{}}
  end

  def change_resource_record_sets(_client, _hosted_zone_id, _input, _options \\ []) do
    {:ok,
     %{
       "ChangeResourceRecordSetsResponse" => %{
         "ChangeInfo" => %{
           "Id" => "/change/C123456789",
           "Status" => "PENDING",
           "SubmittedAt" => "2023-01-01T00:00:00Z"
         }
       }
     }, %{}}
  end

  def create_hosted_zone(_client, _input) do
    {:ok,
     %{
       "CreateHostedZoneResponse" => %{
         "HostedZone" => %{
           "Id" => "/hostedzone/Z987654321",
           "Name" => "test.com.",
           "CallerReference" => "test-ref-123",
           "Config" => %{"PrivateZone" => false, "Comment" => "Test zone"}
         },
         "DelegationSet" => %{
           "NameServers" => [
             "ns-1.awsdns-1.com",
             "ns-2.awsdns-2.net",
             "ns-3.awsdns-3.org",
             "ns-4.awsdns-4.co.uk"
           ]
         }
       }
     }, %{}}
  end

  def delete_hosted_zone(_client, _id, _input \\ nil, _options \\ []) do
    {:ok,
     %{
       "DeleteHostedZoneResponse" => %{
         "ChangeInfo" => %{
           "Id" => "/change/C987654321",
           "Status" => "PENDING",
           "SubmittedAt" => "2023-01-01T00:00:00Z"
         }
       }
     }, %{}}
  end

  def get_hosted_zone(_client, _id, _input \\ nil, _options \\ []) do
    {:ok,
     %{
       "GetHostedZoneResponse" => %{
         "HostedZone" => %{
           "Id" => "/hostedzone/Z123456789",
           "Name" => "example.com.",
           "CallerReference" => "test-ref-123",
           "Config" => %{"PrivateZone" => false, "Comment" => "Test zone"}
         },
         "DelegationSet" => %{
           "NameServers" => [
             "ns-1.awsdns-1.com",
             "ns-2.awsdns-2.net",
             "ns-3.awsdns-3.org",
             "ns-4.awsdns-4.co.uk"
           ]
         }
       }
     }, %{}}
  end

  def get_change(_client, _change_id, _input \\ nil, _options \\ []) do
    {:ok,
     %{
       "GetChangeResponse" => %{
         "ChangeInfo" => %{
           "Id" => "/change/C123456789",
           "Status" => "INSYNC",
           "SubmittedAt" => "2023-01-01T00:00:00Z"
         }
       }
     }, %{}}
  end
end

defmodule GSMLG.AWS.MockClient do
  @moduledoc """
  Mock AWS client that creates a proper AWS.Client struct for testing.
  """

  def create(_access_key_id, _secret_access_key, _region) do
    %AWS.Client{
      access_key_id: "mock_access_key",
      secret_access_key: "mock_secret_key",
      region: "us-east-1",
      endpoint: "https://route53.amazonaws.com",
      service: "route53"
    }
  end
end
