defmodule GSMLGDNS do
  @doc """
  Resolves the answer for a GSMLGDNS query.

  ## Examples

      iex> GSMLGDNS.resolve("tungdao.com")
      {:ok, [{1, 1, 1, 1}]}

      iex> GSMLGDNS.resolve("tungdao.com", :txt)
      {:ok, [['v=spf1 a mx ~all']]}

      iex> GSMLGDNS.resolve("tungdao.com", :a, {"8.8.8.8", 53})
      {:ok, [{1, 1, 1, 1}]}

      iex> GSMLGDNS.resolve("tungdao.com", :a, {"8.8.8.8", 53}, :tcp)
      {:ok, [{1, 1, 1, 1}]}

  """
  @spec resolve(String.t(), atom, {String.t(), :inet.port()}, :tcp | :udp) ::
          {atom, :inet.ip()} | {atom, list} | {atom, atom}
  def resolve(domain, type \\ :a, dns_server \\ {"8.8.8.8", 53}, proto \\ :udp) do
    case query(domain, type, dns_server, proto).anlist do
      answers when is_list(answers) and length(answers) > 0 ->
        data =
          answers
          |> Enum.map(& &1.data)
          |> Enum.reject(&is_nil/1)

        {:ok, data}

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Queries the GSMLGDNS server and returns the result.

  ## Examples

  Queries for A records:

      iex> GSMLGDNS.query("tungdao.com")

  Queries for the MX records:

      iex> GSMLGDNS.query("tungdao.com", :mx)

  Queries for A records, using OpenGSMLGDNS:

      iex> GSMLGDNS.query("tungdao.com", :a, { "208.67.220.220", 53})


  Queries for A records, using OpenGSMLGDNS, with TCP:

      iex> GSMLGDNS.query("tungdao.com", :a, { "208.67.220.220", 53}, :tcp)

  """
  @spec query(String.t(), atom, {String.t(), :inet.port()}, :tcp | :udp) :: GSMLGDNS.Record.t()
  def query(domain, type \\ :a, dns_server \\ {"8.8.8.8", 53}, proto \\ :udp) do
    record = %GSMLGDNS.Record{
      header: %GSMLGDNS.Header{rd: true},
      qdlist: [%GSMLGDNS.Query{domain: to_charlist(domain), type: type, class: :in}]
    }

    encoded_record = GSMLGDNS.Record.encode(record)

    response_data =
      case proto do
        :udp ->
          client = GSMLGSocket.UDP.open!(0)

          GSMLGSocket.Datagram.send!(client, encoded_record, dns_server)

          {data, _server} = GSMLGSocket.Datagram.recv!(client, timeout: 5_000)

          :gen_udp.close(client)

          data

        :tcp ->
          # Set our packet mode to be 2, which indicates there is a 2 byte, big
          # endian length field on our packets sent and recv'd
          socket = GSMLGSocket.TCP.connect!(dns_server, timeout: 5_000, packet: 2)

          :ok = GSMLGSocket.Stream.send(socket, encoded_record)

          data = GSMLGSocket.Stream.recv!(socket)

          GSMLGSocket.Stream.close!(socket)

          data
      end

    GSMLGDNS.Record.decode(response_data)
  end
end
