defmodule GSMLG.Whois do
  @moduledoc """
  Documentation for `GSMLG.Whois`.

  # Lookup Raw Whois

  ```
  GSMLG.Whois.lookup_raw("gsmlg.app")
  ```

  # TODO:

  Add parsed whois infomation.

  """
  require Logger
  alias GSMLG.Whois.Server, as: WhoisServer

  @type restData :: binary()
  @type reason :: :timeout | :closed | {:timeout, restData} | :inet.posix()
  @type opts :: [server: WhoisServer.t()]

  @doc """
  Lookup Whois information of Domain / IP address / AS Number.

  Return a list of whois information.

  format: [{server, raw_whois}, ...]

  ## Options

    - `:server` - Specify a custom WHOIS server
    - `:cache` - Enable/disable caching for this request (default: true)
    - `:type` - Specify lookup type for cache TTL: `:domain`, `:ip`, or `:asn` (default: `:domain`)

  ## Examples

      # Basic lookup with caching
      {:ok, result} = GSMLG.Whois.lookup_raw("example.com")

      # Bypass cache for this lookup
      {:ok, result} = GSMLG.Whois.lookup_raw("example.com", cache: false)

      # Specify IP lookup type for appropriate TTL
      {:ok, result} = GSMLG.Whois.lookup_raw("8.8.8.8", type: :ip)

  Emits telemetry events:
  - `[:gsmlg, :whois, :lookup, :start]`
  - `[:gsmlg, :whois, :lookup, :stop]`
  - `[:gsmlg, :whois, :lookup, :exception]`
  - `[:gsmlg, :whois, :cache, :hit]`
  - `[:gsmlg, :whois, :cache, :miss]`

  """
  @spec lookup_raw(binary(), opts()) :: {:ok, [{binary(), binary()}]} | {:error, reason()}
  def lookup_raw(qs, opts \\ []) do
    cache_enabled = Keyword.get(opts, :cache, true)
    lookup_type = Keyword.get(opts, :type, :domain)

    # Try to get from cache first
    case cache_enabled && GSMLG.Whois.Cache.get(qs) do
      {:ok, cached_result} ->
        emit_telemetry([:gsmlg, :whois, :cache, :hit], %{}, %{query: qs, type: lookup_type})
        {:ok, cached_result}

      :miss ->
        if cache_enabled do
          emit_telemetry([:gsmlg, :whois, :cache, :miss], %{}, %{query: qs, type: lookup_type})
        end

        # Perform actual lookup with telemetry
        GSMLG.Telemetry.span(
          [:gsmlg, :whois, :lookup],
          %{query: qs, type: lookup_type, cached: false},
          fn ->
            result = do_lookup_raw(qs, opts)

            # Cache successful results
            case result do
              {:ok, lookup_result} when cache_enabled ->
                GSMLG.Whois.Cache.put(qs, lookup_result, lookup_type)

              _ ->
                :ok
            end

            result
          end
        )

      false ->
        # Cache disabled for this request
        GSMLG.Telemetry.span(
          [:gsmlg, :whois, :lookup],
          %{query: qs, type: lookup_type, cached: false},
          fn ->
            do_lookup_raw(qs, opts)
          end
        )
    end
  end

  defp do_lookup_raw(qs, opts) do
    server =
      case Keyword.fetch(opts, :server) do
        {:ok, host} when is_binary(host) -> %WhoisServer{host: host}
        {:ok, %WhoisServer{} = server} -> server
        :error -> WhoisServer.root()
      end

    host = server.host
    Logger.debug("Lookup #{qs} on #{host}...")

    with {:ok, socket} <-
           :gen_tcp.connect(
             String.to_charlist(host),
             43,
             [{:active, false}, {:mode, :binary}, {:packet, :line}],
             30_000
           ),
         :ok <- :gen_tcp.send(socket, [qs, "\r\n"]),
         raw when is_binary(raw) <- recv_all(socket) do
      case next_server(raw) do
        nil ->
          {:ok, [{host, raw}]}

        ^host ->
          {:ok, [{host, raw}]}

        "^http://" <> host ->
          {:ok, [{host, raw}]}

        "^https://" <> host ->
          {:ok, [{host, raw}]}

        "" ->
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

  defp recv_all(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        recv_all(socket, acc <> data)

      {:error, :closed} ->
        acc

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp emit_telemetry(event_name, measurements, metadata) do
    :telemetry.execute(event_name, measurements, metadata)
  rescue
    _ -> :ok
  end
end
