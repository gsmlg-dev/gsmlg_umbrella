defmodule GSMLG.Whois do
  @moduledoc """
  Documentation for `GSMLG.Whois`.

  # Lookup Domain Whois

  ```
  GSMLG.Whois.lookup_domain_raw("gsmlg.app")
  ```

  # Lookup IP Whois

  ```
  GSMLG.Whois.lookup_ip_raw("1.1.1.1")
  ```

  # Lookup AS Whois

  ```
  GSMLG.Whois.lookup_as_raw("20473")
  ```

  # Lookup Raw Whois

  ```
  GSMLG.Whois.lookup_raw("gsmlg.app")
  ```

  # TODO:

  Add parsed whois infomation.

  """
  require Logger
  alias GSMLG.Whois.Server, as: WhoisServer

  @doc """
  Lookup Whois information of Domain / IP address / AS Number.

  Return a list of whois information.

  format: [{server, raw_whois}, ...]

  """
  @spec lookup_raw(String.t(), keyword) :: {:ok, List.t()} | {:error, any}
  def lookup_raw(qs, opts \\ []) do
    server =
      case Keyword.fetch(opts, :server) do
        {:ok, host} when is_binary(host) -> %WhoisServer{host: host}
        {:ok, %WhoisServer{} = server} -> server
        :error -> WhoisServer.root()
      end

    host = server.host
    Logger.debug("Lookup #{qs} on #{host}...")

    with {:ok, socket} <- GSMLG.Socket.TCP.connect(host, 43),
         :ok <- GSMLG.Socket.Stream.send(socket, [qs, "\r\n"]) do
      raw = GSMLG.Socket.Stream.recv_all!(socket)

      case next_server(raw) do
        nil ->
          {:ok, [{host, raw}]}

        ^host ->
          {:ok, [{host, raw}]}

        "^http://" <> host ->
          {:ok, [{host, raw}]}

        "^https://" <> host ->
          {:ok, [{host, raw}]}

        next_server ->
          opts = opts |> Keyword.put(:server, next_server)

          case lookup_raw(qs, opts) do
            {:ok, list} ->
              {:ok, [{host, raw} | list]}

            {:error, _} ->
              {:ok, [{host, raw}]}
          end
      end
    else
      {:error, reason} ->
        Logger.debug("Lookup #{qs} on #{host} failed: #{inspect(reason)}")

        {:error, reason}
    end
  end

  @spec lookup_domain_raw(any, keyword) :: {:error, any} | {:ok, binary}
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

  @spec lookup_ip_raw(any, keyword) :: {:error, any} | {:ok, binary}
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

  @spec lookup_as_raw(any, keyword) :: {:error, any} | {:ok, binary}
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
        "whois:" <> host -> String.trim(host)
        "whois server:" <> host -> String.trim(host)
        "registrar whois server:" <> host -> String.trim(host)
        _ -> nil
      end
    end)
  end
end
