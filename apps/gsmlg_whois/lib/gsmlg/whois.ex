defmodule GSMLG.Whois do
  @moduledoc """
  Documentation for `GSMLG.Whois`.
  """

  alias GSMLG.Whois.{Record, Server}

  @type lookup_option :: {:server, String.t() | Server.t()}

  @doc """
  Queries the appropriate WHOIS server for the domain name `domain` and returns
  a `{:ok, %GSMLG.Whois.Record{}}` tuple on success, and `{:error, reason}` on
  failure.
  """
  @spec lookup(String.t(), [lookup_option]) :: {:ok, Record.t()} | {:error, atom}
  def lookup(domain, opts \\ []) do
    with {:ok, raw} <- lookup_raw(domain, opts) do
      {:ok, Record.parse(raw)}
    end
  end

  def lookup_raw(domain, opts \\ []) do
    server =
      case Keyword.fetch(opts, :server) do
        {:ok, host} when is_binary(host) -> {:ok, %Server{host: host}}
        {:ok, %Server{} = server} -> {:ok, server}
        :error -> Server.for_domain(domain)
      end

    case server do
      {:ok, %Server{host: host}} ->
        with {:ok, socket} <- GSMLGSocket.TCP.connect(host, 43),
             :ok <- GSMLGSocket.Stream.send(socket, [domain, "\r\n"]) do
          raw = GSMLGSocket.Stream.recv_all!(socket)

          case next_server(raw) do
            nil ->
              {:ok, raw}

            ^host ->
              {:ok, raw}

            next_server ->
              opts = opts |> Keyword.put(:server, next_server)

              with {:ok, raw2} <- lookup_raw(domain, opts) do
                {:ok, raw <> raw2}
              end
          end
        end

      :error ->
        {:error, :unsupported}
    end
  end

  def lookup_ip_raw(ipaddr, opts \\ []) do
    server =
      case Keyword.fetch(opts, :server) do
        {:ok, host} when is_binary(host) -> {:ok, %Server{host: host}}
        {:ok, %Server{} = server} -> {:ok, server}
        :error -> Server.for_ip(ipaddr)
      end

    case server do
      {:ok, %Server{host: host}} ->
        with {:ok, socket} <- GSMLGSocket.TCP.connect(host, 43),
             :ok <- GSMLGSocket.Stream.send(socket, [ipaddr, "\r\n"]) do
          raw = GSMLGSocket.Stream.recv_all!(socket)

          case next_server(raw) do
            nil ->
              {:ok, raw}

            ^host ->
              {:ok, raw}

            next_server ->
              opts = opts |> Keyword.put(:server, next_server)

              with {:ok, raw2} <- lookup_raw(ipaddr, opts) do
                {:ok, raw <> raw2}
              end
          end
        end

      :error ->
        {:error, :unsupported}
    end
  end

  def lookup_as_raw(asn, opts \\ []) do
    server =
      case Keyword.fetch(opts, :server) do
        {:ok, host} when is_binary(host) -> {:ok, %Server{host: host}}
        {:ok, %Server{} = server} -> {:ok, server}
        :error -> Server.for_asn(asn)
      end

    case server do
      {:ok, %Server{host: host}} ->
        with {:ok, socket} <- GSMLGSocket.TCP.connect(host, 43),
             :ok <- GSMLGSocket.Stream.send(socket, [asn, "\r\n"]) do
          raw = GSMLGSocket.Stream.recv_all!(socket)

          case next_server(raw) do
            nil ->
              {:ok, raw}

            ^host ->
              {:ok, raw}

            next_server ->
              opts = opts |> Keyword.put(:server, next_server)

              with {:ok, raw2} <- lookup_raw(asn, opts) do
                {:ok, raw <> raw2}
              end
          end
        end

      :error ->
        {:error, :unsupported}
    end
  end

  defp next_server(raw) do
    raw
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      line
      |> String.trim()
      |> String.downcase()
      |> case do
        "whois server:" <> host -> String.trim(host)
        "registrar whois server:" <> host -> String.trim(host)
        _ -> nil
      end
    end)
  end
end
