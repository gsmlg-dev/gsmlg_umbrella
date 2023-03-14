defmodule GSMLG.Whois do
  @moduledoc """
  Documentation for `GSMLG.Whois`.
  """

  alias GSMLG.Whois.Server, as: WhoisServer

  @type lookup_option :: {:server, String.t() | WhoisServer.t()}

  def lookup_domain_raw(domain, opts \\ []) do
    server =
      case Keyword.fetch(opts, :server) do
        {:ok, host} when is_binary(host) -> {:ok, %WhoisServer{host: host}}
        {:ok, %WhoisServer{} = server} -> {:ok, server}
        :error -> WhoisServer.for_domain(domain)
      end

    case server do
      {:ok, %WhoisServer{host: host}} ->
        with {:ok, socket} <- GSMLG.Socket.TCP.connect(host, 43),
             :ok <- GSMLG.Socket.Stream.send(socket, [domain, "\r\n"]) do
          raw = GSMLG.Socket.Stream.recv_all!(socket)

          case next_server(raw) do
            nil ->
              {:ok, raw}

            ^host ->
              {:ok, raw}

            next_server ->
              opts = opts |> Keyword.put(:server, next_server)

              with {:ok, raw2} <- lookup_domain_raw(domain, opts) do
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
        {:ok, host} when is_binary(host) -> {:ok, %WhoisServer{host: host}}
        {:ok, %WhoisServer{} = server} -> {:ok, server}
        :error -> WhoisServer.for_ip(ipaddr)
      end

    case server do
      {:ok, %WhoisServer{host: host}} ->
        with {:ok, socket} <- GSMLG.Socket.TCP.connect(host, 43),
             :ok <- GSMLG.Socket.Stream.send(socket, [ipaddr, "\r\n"]) do
          raw = GSMLG.Socket.Stream.recv_all!(socket)

          case next_server(raw) do
            nil ->
              {:ok, raw}

            ^host ->
              {:ok, raw}

            next_server ->
              opts = opts |> Keyword.put(:server, next_server)

              with {:ok, raw2} <- lookup_ip_raw(ipaddr, opts) do
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
        {:ok, host} when is_binary(host) -> {:ok, %WhoisServer{host: host}}
        {:ok, %WhoisServer{} = server} -> {:ok, server}
        :error -> WhoisServer.for_asn(asn)
      end

    case server do
      {:ok, %WhoisServer{host: host}} ->
        with {:ok, socket} <- GSMLG.Socket.TCP.connect(host, 43),
             :ok <- GSMLG.Socket.Stream.send(socket, [asn, "\r\n"]) do
          raw = GSMLG.Socket.Stream.recv_all!(socket)

          case next_server(raw) do
            nil ->
              {:ok, raw}

            ^host ->
              {:ok, raw}

            next_server ->
              opts = opts |> Keyword.put(:server, next_server)

              with {:ok, raw2} <- lookup_as_raw(asn, opts) do
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
