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

  @doc """
  Lookup Whois information of Domain / IP address / AS Number.

  Return a list of whois information.

  format: [{server, raw_whois}, ...]

  """
  @spec lookup_raw(String.t(), Keyword.t()) :: {:ok, List.t()} | {:error, any()}
  def lookup_raw(qs, opts \\ []) do
    server =
      case Keyword.fetch(opts, :server) do
        {:ok, host} when is_binary(host) -> %WhoisServer{host: host}
        {:ok, %WhoisServer{} = server} -> server
        :error -> WhoisServer.root()
      end

    host = server.host
    Logger.debug("Lookup #{qs} on #{host}...")

    with {:ok, socket} <- :gen_tcp.connect(String.to_charlist(host), 43, [{:active, :false},{:mode, :binary},{:packet, :line}], 10_000),
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
        IO.inspect(data)
        recv_all(socket, acc <> data)
      {:error, :closed} -> acc
      {:error, reason} -> {:error, reason}
    end
  end
end
