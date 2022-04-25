defmodule GSMLGSocket do
  @type t :: GSMLGSocket.Protocol.t()

  @default_port_ws 80
  @default_port_wss 443

  defmodule Error do
    defexception message: nil

    def exception(reason: reason) do
      message =
        cond do
          msg = GSMLGSocket.TCP.error(reason) ->
            msg

          msg = GSMLGSocket.SSL.error(reason) ->
            msg

          true ->
            reason |> to_string
        end

      %Error{message: message}
    end
  end

  @doc ~S"""
  Create a socket connecting to somewhere using an URI.
  ## Supported URIs
  * `tcp://host:port` for GSMLGSocket.TCP
  * `ssl://host:port` for GSMLGSocket.SSL
  * `ws://host:port/path` for GSMLGSocket.Web (using GSMLGSocket.TCP)
  * `wss://host:port/path` for GSMLGSocket.Web (using GSMLGSocket.SSL)
  * `udp://host:port` for GSMLGSocket:UDP
  ## Example
      { :ok, client } = GSMLGSocket.connect "tcp://google.com:80"
      client.send "GET / HTTP/1.1\r\n"
      client.recv
  """
  @spec connect(String.t() | URI.t()) :: {:ok, GSMLGSocket.t()} | {:error, any}
  def connect(uri) when uri |> is_list or uri |> is_binary do
    connect(URI.parse(uri))
  end

  def connect(%URI{scheme: "tcp", host: host, port: port}) do
    GSMLGSocket.TCP.connect(host, port)
  end

  def connect(%URI{scheme: "ssl", host: host, port: port}) do
    GSMLGSocket.SSL.connect(host, port)
  end

  def connect(%URI{scheme: "ws", host: host, port: port, path: path}) do
    GSMLGSocket.Web.connect(host, port || @default_port_ws, path: path)
  end

  def connect(%URI{scheme: "wss", host: host, port: port, path: path}) do
    GSMLGSocket.Web.connect(host, port || @default_port_wss, path: path, secure: true)
  end

  @doc """
  Create a socket connecting to somewhere using an URI, raising if an error
  occurs, see `connect`.
  """
  @spec connect!(String.t() | URI.t()) :: GSMLGSocket.t() | no_return
  def connect!(uri) when uri |> is_list or uri |> is_binary do
    connect!(URI.parse(uri))
  end

  def connect!(%URI{scheme: "tcp", host: host, port: port}) do
    GSMLGSocket.TCP.connect!(host, port)
  end

  def connect!(%URI{scheme: "ssl", host: host, port: port}) do
    GSMLGSocket.SSL.connect!(host, port)
  end

  def connect!(%URI{scheme: "ws", host: host, port: port, path: path}) do
    GSMLGSocket.Web.connect!(host, port || @default_port_ws, path: path)
  end

  def connect!(%URI{scheme: "wss", host: host, port: port, path: path}) do
    GSMLGSocket.Web.connect!(host, port || @default_port_wss, path: path, secure: true)
  end

  @doc """
  Create a socket listening somewhere using an URI.
  ## Supported URIs
  If host is `*` it will be converted to `0.0.0.0`.
  * `tcp://host:port` for GSMLGSocket.TCP
  * `ssl://host:port` for GSMLGSocket.SSL
  * `ws://host:port/path` for GSMLGSocket.Web (using GSMLGSocket.TCP)
  * `wss://host:port/path` for GSMLGSocket.Web (using GSMLGSocket.SSL)
  * `udp://host:port` for GSMLGSocket:UDP
  ## Example
      { :ok, server } = GSMLGSocket.listen "tcp://*:1337"
      client = server |> GSMLGSocket.accept!(packet: :line)
      client |> GSMLGSocket.Stream.send(client.recv)
      client |> GSMLGSocket.Stream.close
  """
  @spec listen(String.t() | URI.t()) :: {:ok, GSMLGSocket.t()} | {:error, any}
  def listen(uri) when uri |> is_list or uri |> is_binary do
    listen(URI.parse(uri))
  end

  def listen(%URI{scheme: "tcp", host: host, port: port}) do
    GSMLGSocket.TCP.listen(port, local: [address: if(host == "*", do: "0.0.0.0", else: host)])
  end

  def listen(%URI{scheme: "ssl", host: host, port: port}) do
    GSMLGSocket.SSL.listen(port, local: [address: if(host == "*", do: "0.0.0.0", else: host)])
  end

  def listen(%URI{scheme: "ws", host: host, port: port}) do
    GSMLGSocket.Web.listen(port || @default_port_ws,
      local: [address: if(host == "*", do: "0.0.0.0", else: host)]
    )
  end

  def listen(%URI{scheme: "wss", host: host, port: port}) do
    GSMLGSocket.Web.listen(port || @default_port_wss,
      secure: true,
      local: [address: if(host == "*", do: "0.0.0.0", else: host)]
    )
  end

  @doc """
  Create a socket listening somewhere using an URI, raising if an error occurs,
  see `listen`.
  """
  @spec listen!(String.t() | URI.t()) :: GSMLGSocket.t() | no_return
  def listen!(uri) when uri |> is_list or uri |> is_binary do
    listen!(URI.parse(uri))
  end

  def listen!(%URI{scheme: "tcp", host: host, port: port}) do
    GSMLGSocket.TCP.listen!(port, local: [address: if(host == "*", do: "0.0.0.0", else: host)])
  end

  def listen!(%URI{scheme: "ssl", host: host, port: port}) do
    GSMLGSocket.SSL.listen!(port, local: [address: if(host == "*", do: "0.0.0.0", else: host)])
  end

  def listen!(%URI{scheme: "ws", host: host, port: port}) do
    GSMLGSocket.Web.listen!(port || @default_port_ws,
      local: [address: if(host == "*", do: "0.0.0.0", else: host)]
    )
  end

  def listen!(%URI{scheme: "wss", host: host, port: port}) do
    GSMLGSocket.Web.listen!(port || @default_port_wss,
      secure: true,
      local: [address: if(host == "*", do: "0.0.0.0", else: host)]
    )
  end

  @doc false
  def arguments(options) do
    options =
      options
      |> Keyword.put_new(:mode, :passive)

    Enum.flat_map(options, fn
      {:mode, :active} ->
        [{:active, true}]

      {:mode, :once} ->
        [{:active, :once}]

      {:mode, :passive} ->
        [{:active, false}]

      {:route, true} ->
        [{:dontroute, false}]

      {:route, false} ->
        [{:dontroute, true}]

      {:reuse, true} ->
        [{:reuseaddr, true}]

      {:reuse, false} ->
        []

      {:linger, value} ->
        [{:linger, {true, value}}]

      {:priority, value} ->
        [{:priority, value}]

      {:tos, value} ->
        [{:tos, value}]

      {:send, options} ->
        Enum.flat_map(options, fn
          {:timeout, {timeout, :close}} ->
            [{:send_timeout, timeout}, {:send_timeout_close, true}]

          {:timeout, timeout} when timeout |> is_integer ->
            [{:send_timeout, timeout}]

          {:delay, delay} ->
            [{:delay_send, delay}]

          {:buffer, buffer} ->
            [{:sndbuf, buffer}]
        end)

      {:recv, options} ->
        Enum.flat_map(options, fn
          {:buffer, buffer} ->
            [{:recbuf, buffer}]
        end)
    end)
  end

  use GSMLGSocket.Helpers

  defdelegate equal?(self, other), to: GSMLGSocket.Protocol

  defdelegate accept(self), to: GSMLGSocket.Protocol
  defbang(accept(self), to: GSMLGSocket.Protocol)

  defdelegate accept(self, options), to: GSMLGSocket.Protocol
  defbang(accept(self, options), to: GSMLGSocket.Protocol)

  defdelegate options(self, opts), to: GSMLGSocket.Protocol
  defbang(options(self, opts), to: GSMLGSocket.Protocol)

  defdelegate packet(self, type), to: GSMLGSocket.Protocol
  defbang(packet(self, type), to: GSMLGSocket.Protocol)

  defdelegate process(self, pid), to: GSMLGSocket.Protocol
  defbang(process(self, pid), to: GSMLGSocket.Protocol)

  defdelegate active(self), to: GSMLGSocket.Protocol
  defbang(active(self), to: GSMLGSocket.Protocol)

  defdelegate active(self, mode), to: GSMLGSocket.Protocol
  defbang(active(self, mode), to: GSMLGSocket.Protocol)

  defdelegate passive(self), to: GSMLGSocket.Protocol
  defbang(passive(self), to: GSMLGSocket.Protocol)

  defdelegate local(self), to: GSMLGSocket.Protocol
  defbang(local(self), to: GSMLGSocket.Protocol)

  defdelegate remote(self), to: GSMLGSocket.Protocol
  defbang(remote(self), to: GSMLGSocket.Protocol)

  defdelegate close(self), to: GSMLGSocket.Protocol
  defbang(close(self), to: GSMLGSocket.Protocol)
end

defprotocol GSMLGSocket.Protocol do
  @doc """
  Check the two sockets are the same.
  """
  @spec equal?(t, t) :: boolean
  def equal?(self, other)

  @doc """
  Accept a connection from the socket.
  """
  @spec accept(t) :: {:ok, t} | {:error, term}
  @spec accept(t, Keyword.t()) :: {:ok, t} | {:error, term}
  def accept(self, options \\ [])

  @doc """
  Set options for the socket.
  """
  @spec options(t, Keyword.t()) :: :ok | {:error, term}
  def options(self, opts)

  @doc """
  Change the packet type of the socket.
  """
  @spec packet(t, atom) :: :ok | {:error, term}
  def packet(self, type)

  @doc """
  Change the controlling process of the socket.
  """
  @spec process(t, pid) :: :ok | {:error, term}
  def process(self, pid)

  @doc """
  Make the socket active.
  """
  @spec active(t) :: :ok | {:error, term}
  def active(self)

  @doc """
  Make the socket active once.
  """
  @spec active(t, :once) :: :ok | {:error, term}
  def active(self, mode)

  @doc """
  Make the socket passive.
  """
  @spec passive(t) :: :ok | {:error, term}
  def passive(self)

  @doc """
  Get the local address/port of the socket.
  """
  @spec local(t) :: {:ok, {Socket.Address.t(), :inet.port_number()}} | {:error, term}
  def local(self)

  @doc """
  Get the remote address/port of the socket.
  """
  @spec remote(t) :: {:ok, {Socket.Address.t(), :inet.port_number()}} | {:error, term}
  def remote(self)

  @doc """
  Close the socket.
  """
  @spec close(t) :: :ok | {:error, term}
  def close(self)
end

defimpl GSMLGSocket.Protocol, for: Port do
  def equal?(self, other) when other |> is_port do
    self == other
  end

  def equal?(self, other) do
    self == elem(other, 1)
  end

  def accept(self, options \\ []) do
    case :inet_db.lookup_socket(self) do
      {:ok, mod} when mod in [:inet_tcp, :inet6_tcp] ->
        GSMLGSocket.TCP.accept(self, options)

      {:ok, mod} when mod in [:inet_udp, :inet6_udp] ->
        {:error, :einval}
    end
  end

  def options(self, opts) do
    :inet.setopts(self, GSMLGSocket.arguments(opts))
  end

  def packet(self, type) do
    :inet.setopts(self, packet: type)
  end

  def process(self, pid) do
    case :inet_db.lookup_socket(self) do
      {:ok, mod} when mod in [:inet_tcp, :inet6_tcp] ->
        :gen_tcp.controlling_process(self, pid)

      {:ok, mod} when mod in [:inet_udp, :inet6_udp] ->
        :gen_udp.controlling_process(self, pid)
    end
  end

  def active(self) do
    :inet.setopts(self, active: true)
  end

  def active(self, :once) do
    :inet.setopts(self, active: :once)
  end

  def passive(self) do
    :inet.setopts(self, active: false)
  end

  def local(self) do
    :inet.sockname(self)
  end

  def remote(self) do
    :inet.peername(self)
  end

  def close(self) do
    :inet.close(self)
  end
end

defimpl GSMLGSocket.Protocol, for: Tuple do
  require Record

  def equal?(self, other)
      when self |> Record.is_record(:sslsocket) and other |> Record.is_record(:sslsocket) do
    self == other
  end

  def equal?(self, other) when self |> Record.is_record(:sslsocket) do
    self |> elem(1) == other
  end

  def equal?(_, _) do
    false
  end

  def accept(self, options \\ []) when self |> Record.is_record(:sslsocket) do
    GSMLGSocket.SSL.accept(self, options)
  end

  def options(self, opts) when self |> Record.is_record(:sslsocket) do
    GSMLGSocket.SSL.options(self, opts)
  end

  def packet(self, type) when self |> Record.is_record(:sslsocket) do
    :ssl.setopts(self, packet: type)
  end

  def process(self, pid) when self |> Record.is_record(:sslsocket) do
    :ssl.controlling_process(self, pid)
  end

  def active(self) when self |> Record.is_record(:sslsocket) do
    :ssl.setopts(self, active: true)
  end

  def active(self, :once) when self |> Record.is_record(:sslsocket) do
    :ssl.setopts(self, active: :once)
  end

  def passive(self) when self |> Record.is_record(:sslsocket) do
    :ssl.setopts(self, active: false)
  end

  def local(self) when self |> Record.is_record(:sslsocket) do
    :ssl.sockname(self)
  end

  def remote(self) when self |> Record.is_record(:sslsocket) do
    :ssl.peername(self)
  end

  def close(self) when self |> Record.is_record(:sslsocket) do
    :ssl.close(self)
  end
end
