defmodule GSMLGYellowDog.Server do
  @moduledoc """
  Implementing GSMLGDNS.Server behaviour
  """
  @behaviour GSMLGDNS.Server
  use GSMLGDNS.Server
  require Logger

  def handle(record, _client) do
    # record: %GSMLGDNS.Record{
    #   anlist: [],
    #   arlist: [%GSMLGDNS.ResourceOpt{
    #     data: <<0, 10, 0, 8, 97, 227, 140, 70, 17, 115, 176, 108>>,
    #     domain: '.', ext_rcode: 0, type: :opt, udp_payload_size: 4096, version: 0, z: 0
    #   }],
    #   header: %GSMLGDNS.Header{
    #     aa: false, id: 27018, opcode: :query, pr: false, qr: false, ra: false, rcode: 0, rd: true, tc: false
    #   },
    #   nslist: [],
    #   qdlist: [%GSMLGDNS.Query{
    #     class: :in,
    #     domain: 'zdns.cn',
    #     type: :aaaa,
    #     unicast_response: false
    #   }]
    # }
    # Logger.info(fn -> "#{inspect(record)}" end)
    query = hd(record.qdlist)
    # query: %GSMLGDNS.Query{class: :in, domain: 'zdns.cn', type: :a, unicast_response: false}
    Logger.info(fn -> "Query: #{inspect(query)}" end)

    case GSMLGYellowDog.Zone.findByDomain(query.domain, query.type) do
      {:noerror, resourcs} ->
        %{
          record
          | header: %{
              record.header
              | qr: true,
                ra: false,
                aa: true,
                rcode: GSMLGYellowDog.RCode.to_code(:noerror)
            },
            anlist: resourcs,
            arlist: []
        }

      {:refused} ->
        %{
          record
          | header: %{
              record.header
              | qr: true,
                ra: false,
                aa: true,
                rcode: GSMLGYellowDog.RCode.to_code(:refused)
            },
            anlist: [],
            arlist: []
        }

      _ ->
        %{
          record
          | header: %{record.header | qr: true, ra: false, aa: true, rcode: 2},
            anlist: [],
            arlist: []
        }
    end
  end
end
