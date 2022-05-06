defmodule GSMLGDNS.Server do
  @moduledoc """
  GSMLGDNS server based on `GenServer`.
  """

  @callback handle(GSMLGDNS.Record.t(), {:inet.ip(), :inet.port()}) :: GSMLGDNS.Record.t()

  defmacro __using__(_) do
    quote [] do
      use GenServer

      @doc """
      Start GSMLGDNS.Server` server.

      ## Options

      * `:port` - set the port number for the server
      """
      def start_link(name: name, port: port) do
        GenServer.start_link(name, [port])
      end

      def init([port]) do
        socket = GSMLGSocket.UDP.open!(port, as: :binary, mode: :active)
        IO.puts("DNS Server listening at #{port}")

        # accept_loop(socket, handler)
        {:ok, %{port: port, socket: socket}}
      end

      def handle_info({:udp, client, ip, wtv, data}, state) do
        record = GSMLGDNS.Record.decode(data)
        response = handle(record, client)
        GSMLGSocket.Datagram.send!(state.socket, GSMLGDNS.Record.encode(response), {ip, wtv})
        {:noreply, state}
      end
    end
  end
end
