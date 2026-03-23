defmodule GSMLG.Whois.WhoisProtocol do
  @moduledoc """
  TCP WHOIS lookup protocol (RFC 3912).

  Connects to a WHOIS server on port 43, sends the query, reads the raw
  text response, and recursively follows referrals to authoritative servers
  when the response contains a `whois:` or `whois server:` header.

  Returns a list of `{server_host, raw_text}` pairs — one per server
  contacted, with the root server first.
  """

  require Logger

  alias GSMLG.Whois.Server

  @type result :: {:ok, [{binary(), binary()}]} | {:error, term()}

  @doc """
  Performs a raw WHOIS lookup starting from the given server.

  ## Options

    - `:server` — override the initial WHOIS server (binary hostname or `%Server{}`)

  ## Examples

      {:ok, results} = GSMLG.Whois.WhoisProtocol.lookup("example.com", Server.root())
  """
  @spec lookup(binary(), Server.t()) :: result()
  def lookup(query, server) do
    host = server.host
    Logger.debug("WHOIS lookup #{query} on #{host}")

    with {:ok, socket} <-
           :gen_tcp.connect(
             String.to_charlist(host),
             43,
             [{:active, false}, {:mode, :binary}, {:packet, :line}],
             30_000
           ),
         :ok <- :gen_tcp.send(socket, [query, "\r\n"]),
         raw when is_binary(raw) <- recv_all(socket) do
      case next_server(raw) do
        nil -> {:ok, [{host, raw}]}
        ^host -> {:ok, [{host, raw}]}
        "" -> {:ok, [{host, raw}]}
        "^http://" <> _ -> {:ok, [{host, raw}]}
        "^https://" <> _ -> {:ok, [{host, raw}]}
        next_host ->
          case lookup(query, %Server{host: next_host}) do
            {:ok, rest} -> {:ok, [{host, raw} | rest]}
            {:error, _} -> {:ok, [{host, raw}]}
          end
      end
    else
      {:error, reason} ->
        Logger.debug("WHOIS lookup #{query} on #{host} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp recv_all(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, :closed} -> acc
      {:error, reason} -> {:error, reason}
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
