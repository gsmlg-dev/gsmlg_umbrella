defmodule GSMLG.Socket.SSL do
  @moduledoc """
  This module allows usage of SSL sockets and promotion of TCP sockets to SSL
  sockets.

  ## Options

  When creating a socket you can pass a series of options to use for it.

  * `:cert` can either be an encoded certificate or `[path:
    "path/to/certificate"]`
  * `:key` can either be an encoded certificate, `[path: "path/to/key"]`, `[rsa:
    "rsa encoded"]` or `[dsa: "dsa encoded"]` or `[ec: "ec encoded"]`
  * `:authorities` can iehter be an encoded authorities or `[path:
    "path/to/authorities"]`
  * `:dh` can either be an encoded dh or `[path: "path/to/dh"]`
  * `:verify` can either be `false` to disable peer certificate verification,
    or a keyword list containing a `:function` and an optional `:data`
  * `:password` the password to use to decrypt certificates
  * `:renegotiation` if it's set to `:secure` renegotiation will be secured
  * `:ciphers` is a list of ciphers to allow
  * `:advertised_protocols` is a list of strings representing the advertised
    protocols for NPN
  * `:preferred_protocols` is a list of strings representing the preferred next
    protocols for NPN

  You can also pass TCP options.

  ## Smart garbage collection

  Normally sockets in Erlang are closed when the controlling process exits,
  with smart garbage collection the controlling process will be the
  `GSMLG.Socket.Manager` and it will be closed when there are no more references to
  it.
  """

  use GSMLG.Socket.Helpers
  require Record

  @opaque t :: port

  @doc """
  Get the list of supported ciphers.
  """
  @spec ciphers :: [:ssl.erl_cipher_suite()]
  def ciphers do
    :ssl.cipher_suites(:all, :"tlsv1.3")
  end

  @doc """
  Get the list of supported SSL/TLS versions.
  """
  @spec versions :: [tuple]
  def versions do
    :ssl.versions()
  end

  @doc """
  Return a proper error string for the given code or nil if it can't be
  converted.
  """
  @spec error(term) :: String.t()
  def error(code) do
    case :ssl.format_error(code) do
      ~c"Unexpected error:" ++ _ ->
        nil

      message ->
        message |> to_string
    end
  end

  @doc """
  Connect to the given address and port tuple or SSL connect the given socket.
  """
  @spec connect(GSMLG.Socket.t() | {GSMLG.Socket.t(), :inet.port_number()}) ::
          {:ok, t} | {:error, term}
  def connect({address, port}) do
    connect(address, port)
  end

  def connect(socket) do
    connect(socket, [])
  end

  @doc """
  Connect to the given address and port tuple or SSL connect the given socket,
  raising if an error occurs.
  """
  @spec connect!(GSMLG.Socket.t() | {GSMLG.Socket.t(), :inet.port_number()}) :: t | no_return
  defbang(connect(socket_or_descriptor))

  @doc """
  Connect to the given address and port tuple with the given options or SSL
  connect the given socket with the given options or connect to the given
  address and port.
  """
  @spec connect(
          {GSMLG.Socket.Address.t(), :inet.port_number()}
          | GSMLG.Socket.t()
          | GSMLG.Socket.Address.t(),
          Keyword.t() | :inet.port_number()
        ) :: {:ok, t} | {:error, term}
  def connect({address, port}, options) when options |> is_list do
    connect(address, port, options)
  end

  def connect(wrap, options) when options |> is_list do
    wrap =
      unless wrap |> is_port do
        wrap.to_port
      else
        wrap
      end

    timeout = options[:timeout] || :infinity
    options = Keyword.delete(options, :timeout)

    :ssl.connect(wrap, options, timeout)
  end

  def connect(address, port) when port |> is_integer do
    connect(address, port, [])
  end

  @doc """
  Connect to the given address and port tuple with the given options or SSL
  connect the given socket with the given options or connect to the given
  address and port, raising if an error occurs.
  """
  @spec connect!(
          {GSMLG.Socket.Address.t(), :inet.port_number()}
          | GSMLG.Socket.t()
          | GSMLG.Socket.Address.t(),
          Keyword.t() | :inet.port_number()
        ) :: t | no_return
  defbang(connect(descriptor, options))

  @doc """
  Connect to the given address and port with the given options.
  """
  @spec connect(GSMLG.Socket.Address.t(), :inet.port_number(), Keyword.t()) ::
          {:ok, t} | {:error, term}
  def connect(address, port, options) do
    address_str = if is_binary(address), do: address, else: inspect(address)

    address =
      if address |> is_binary do
        String.to_charlist(address)
      else
        address
      end

    timeout = options[:timeout] || :infinity
    options = Keyword.delete(options, :timeout)

    metadata = %{
      socket_type: :ssl,
      host: address_str,
      port: port,
      timeout: timeout,
      module: __MODULE__,
      tls_versions: options[:versions] || [:"tlsv1.3", :"tlsv1.2"]
    }

    GSMLG.Socket.Telemetry.span(:ssl_connect, metadata, fn ->
      case :ssl.connect(address, port, arguments(options), timeout) do
        {:ok, socket} = result ->
          # Log successful SSL connection with security details
          conn_info = :ssl.connection_information(socket)

          ssl_metadata = %{
            host: address_str,
            port: port,
            protocol: get_in(conn_info, [:ok, :protocol]),
            cipher: get_in(conn_info, [:ok, :cipher_suite]),
            sni: get_in(conn_info, [:ok, :sni_hostname])
          }

          GSMLG.Socket.Telemetry.log_security(
            "SSL connection established: #{address_str}:#{port}",
            ssl_metadata
          )

          {result, %{success: true, ssl_info: ssl_metadata}}

        {:error, reason} = error ->
          # Log SSL connection failure with security context
          error_msg = error(reason) || inspect(reason)

          GSMLG.Socket.Telemetry.log_security(
            "SSL connection failed: #{address_str}:#{port} - #{error_msg}",
            %{
              host: address_str,
              port: port,
              reason: reason,
              error_type: categorize_ssl_error(reason)
            }
          )

          {error, %{success: false, error: reason}}
      end
    end)
  end

  # Categorize SSL errors for better debugging
  defp categorize_ssl_error({:tls_alert, {:handshake_failure, _}}), do: :handshake_failure
  defp categorize_ssl_error({:tls_alert, {:certificate_unknown, _}}), do: :certificate_error
  defp categorize_ssl_error({:tls_alert, {:bad_certificate, _}}), do: :certificate_error
  defp categorize_ssl_error({:tls_alert, _}), do: :tls_alert
  defp categorize_ssl_error(:timeout), do: :timeout
  defp categorize_ssl_error(:econnrefused), do: :connection_refused
  defp categorize_ssl_error(_), do: :unknown

  @doc """
  Connect to the given address and port with the given options, raising if an
  error occurs.
  """
  @spec connect!(GSMLG.Socket.Address.t(), :inet.port_number(), Keyword.t()) :: t | no_return
  defbang(connect(address, port, options))

  @doc """
  Create an SSL socket listening on an OS chosen port, use `local` to know the
  port it was bound on.
  """
  @spec listen :: {:ok, t} | {:error, term}
  def listen do
    listen(0, [])
  end

  @doc """
  Create an SSL socket listening on an OS chosen port, use `local` to know the
  port it was bound on, raising in case of error.
  """
  @spec listen! :: t | no_return
  defbang(listen)

  @doc """
  Create an SSL socket listening on an OS chosen port using the given options or
  listening on the given port.
  """
  @spec listen(:inet.port_number() | Keyword.t()) :: {:ok, t} | {:error, term}
  def listen(port) when port |> is_integer do
    listen(port, [])
  end

  def listen(options) do
    listen(0, options)
  end

  @doc """
  Create an SSL socket listening on an OS chosen port using the given options
  or listening on the given port, raising in case of error.
  """
  @spec listen!(:inet.port_number() | Keyword.t()) :: t | no_return
  defbang(listen(port_or_options))

  @doc """
  Create an SSL socket listening on the given port and using the given options.
  """
  @spec listen(:inet.port_number(), Keyword.t()) :: {:ok, t} | {:error, term}
  def listen(port, options) do
    options = Keyword.put(options, :mode, :passive)
    options = Keyword.put_new(options, :reuse, true)

    :ssl.listen(port, arguments(options))
  end

  @doc """
  Create an SSL socket listening on the given port and using the given options,
  raising in case of error.
  """
  @spec listen!(:inet.port_number(), Keyword.t()) :: t | no_return
  defbang(listen(port, options))

  @doc """
  Accept a connection from a listening SSL socket or start an SSL connection on
  the given client socket.
  """
  @spec accept(GSMLG.Socket.t() | t) :: {:ok, t} | {:error, term}
  def accept(self) do
    accept(self, [])
  end

  @doc """
  Accept a connection from a listening SSL socket or start an SSL connection on
  the given client socket, raising if an error occurs.
  """
  @spec accept!(GSMLG.Socket.t() | t) :: t | no_return
  defbang(accept(socket))

  @doc """
  Accept a connection from a listening SSL socket with the given options or
  start an SSL connection on the given client socket with the given options.
  """
  @spec accept(GSMLG.Socket.t(), Keyword.t()) :: {:ok, t} | {:error, term}
  def accept(socket, options) when socket |> Record.is_record(:sslsocket) do
    timeout = options[:timeout] || :infinity

    with {:ok, socket} <- socket |> :ssl.transport_accept(timeout),
         :ok <-
           if(options[:mode] == :active, do: socket |> :ssl.setopts([{:active, true}]), else: :ok),
         :ok <- socket |> handshake(timeout: timeout) do
      {:ok, socket}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  def accept(wrap, options) when wrap |> is_port do
    timeout = options[:timeout] || :infinity
    options = Keyword.delete(options, :timeout)

    :ssl.handshake(wrap, arguments(options), timeout)
  end

  @doc """
  Accept a connection from a listening SSL socket with the given options or
  start an SSL connection on the given client socket with the given options,
  raising if an error occurs.
  """
  @spec accept!(GSMLG.Socket.t(), t | Keyword.t()) :: t | no_return
  defbang(accept(socket, options))

  @doc """
  Execute the handshake; useful if you want to delay the handshake to make it
  in another process.
  """
  @spec handshake(t) :: :ok | {:error, term}
  @spec handshake(t, Keyword.t()) :: :ok | {:error, term}
  def handshake(socket, options \\ []) when socket |> Record.is_record(:sslsocket) do
    timeout = options[:timeout] || :infinity

    metadata = %{
      socket_type: :ssl,
      operation: :handshake,
      timeout: timeout,
      module: __MODULE__
    }

    GSMLG.Socket.Telemetry.span(:ssl_handshake, metadata, fn ->
      case :ssl.handshake(socket, timeout) do
        :ok = result ->
          GSMLG.Socket.Telemetry.log_security("SSL handshake completed", %{
            operation: :handshake
          })

          {result, %{success: true}}

        {:error, reason} = error ->
          GSMLG.Socket.Telemetry.log_security(
            "SSL handshake failed: #{inspect(reason)}",
            %{
              operation: :handshake,
              reason: reason,
              error_type: categorize_ssl_error(reason)
            }
          )

          {error, %{success: false, error: reason}}
      end
    end)
  end

  @doc """
  Execute the handshake, raising if an error occurs; useful if you want to
  delay the handshake to make it in another process.
  """
  @spec handshake!(t) :: :ok | no_return
  @spec handshake!(t, Keyword.t()) :: :ok | no_return
  defbang(handshake(socket))
  defbang(handshake(socket, options))

  @doc """
  Set the process which will receive the messages.
  """
  @spec process(t | port, pid) :: :ok | {:error, :closed | :not_owner | Error.t()}
  def process(socket, pid) when socket |> Record.is_record(:sslsocket) do
    :ssl.controlling_process(socket, pid)
  end

  @doc """
  Set the process which will receive the messages, raising if an error occurs.
  """
  @spec process!(t | port, pid) :: :ok | no_return
  def process!(socket, pid) do
    case process(socket, pid) do
      :ok ->
        :ok

      :closed ->
        raise RuntimeError, message: "the socket is closed"

      :not_owner ->
        raise RuntimeError, message: "the current process isn't the owner"

      code ->
        raise GSMLG.Socket.Error, reason: code
    end
  end

  @doc """
  Set options of the socket.
  """
  @spec options(t | :ssl.sslsocket(), Keyword.t()) :: :ok | {:error, GSMLG.Socket.Error.t()}
  def options(socket, options) when socket |> Record.is_record(:sslsocket) do
    :ssl.setopts(socket, arguments(options))
  end

  @doc """
  Set options of the socket, raising if an error occurs.
  """
  @spec options!(t | GSMLG.Socket.SSL.t() | port, Keyword.t()) :: :ok | no_return
  defbang(options(socket, options))

  @doc """
  Convert SSL options to `:ssl.setopts` compatible arguments.

  ## Security Defaults

  By default, this function enforces the following security settings:
  - TLS versions: Only TLS 1.2 and TLS 1.3 are enabled (unless explicitly overridden)
  - Certificate verification: Defaults to `:verify_peer` for client connections

  To disable these defaults (not recommended for production), explicitly set `:versions`
  or `:verify` options.
  """
  @spec arguments(Keyword.t()) :: list
  def arguments(options) do
    # Apply security defaults
    options =
      options
      |> Keyword.put_new(:versions, [:"tlsv1.3", :"tlsv1.2"])

    options =
      Enum.group_by(options, fn
        {:server_name, _} -> true
        {:cert, _} -> true
        {:key, _} -> true
        {:authorities, _} -> true
        {:sni, _} -> true
        {:dh, _} -> true
        {:verify, _} -> true
        {:password, _} -> true
        {:renegotiation, _} -> true
        {:ciphers, _} -> true
        {:depth, _} -> true
        {:identity, _} -> true
        {:versions, _} -> true
        {:alert, _} -> true
        {:hibernate, _} -> true
        {:session, _} -> true
        {:advertised_protocols, _} -> true
        {:preferred_protocols, _} -> true
        _ -> false
      end)

    {local, global} = {
      Map.get(options, true, []),
      Map.get(options, false, [])
    }

    GSMLG.Socket.TCP.arguments(global) ++
      Enum.flat_map(local, fn
        {:server_name, false} ->
          [{:server_name_indication, :disable}]

        {:server_name, name} ->
          [{:server_name_indication, String.to_charlist(name)}]

        {:cert, [path: path]} ->
          [{:certfile, path}]

        {:cert, cert} ->
          [{:cert, cert}]

        {:key, [path: path]} ->
          [{:keyfile, path}]

        {:key, [rsa: key]} ->
          [{:key, {:RSAPrivateKey, key}}]

        {:key, [dsa: key]} ->
          [{:key, {:DSAPrivateKey, key}}]

        {:key, [ec: key]} ->
          [{:key, {:ECPrivateKey, key}}]

        {:key, key} ->
          [{:key, {:PrivateKeyInfo, key}}]

        {:authorities, [path: path]} ->
          [{:cacertfile, path}]

        {:authorities, ca} ->
          [{:cacerts, ca}]

        {:dh, [path: path]} ->
          [{:dhfile, path}]

        {:dh, dh} ->
          [{:dh, dh}]

        {:sni, sni} ->
          Enum.flat_map(sni, fn
            {:hosts, hosts} ->
              [
                {:sni_hosts,
                 Enum.map(hosts, fn {name, options} ->
                   {String.to_charlist(name), arguments(options)}
                 end)}
              ]

            {:function, fun} ->
              [{:sni_fun, fun}]
          end)

        {:verify, false} ->
          [{:verify, :verify_none}]

        {:verify, [function: fun]} ->
          [{:verify_fun, {fun, nil}}]

        {:verify, [function: fun, data: data]} ->
          [{:verify_fun, {fun, data}}]

        {:identity, identity} ->
          Enum.flat_map(identity, fn
            {:psk, value} ->
              [{:psk_identity, String.to_charlist(value)}]

            {:srp, {first, second}} ->
              [{:srp_identity, {String.to_charlist(first), String.to_charlist(second)}}]
          end)

        {:password, password} ->
          [{:password, String.to_charlist(password)}]

        {:renegotiation, :secure} ->
          [{:secure_renegotiate, true}]

        {:ciphers, ciphers} ->
          [{:ciphers, ciphers}]

        {:depth, depth} ->
          [{:depth, depth}]

        {:versions, versions} ->
          [{:versions, versions}]

        {:alert, value} ->
          [{:log_alert, value}]

        {:hibernate, hibernate} ->
          [{:hibernate_after, hibernate}]

        {:session, session} ->
          Enum.flat_map(session, fn
            {:reuse, true} ->
              [{:reuse_sessions, true}]

            {:reuse, false} ->
              [{:reuse_sessions, false}]

            {:reuse, fun} when fun |> is_function ->
              [{:reuse_session, fun}]
          end)

        {:advertised_protocols, protocols} ->
          [{:next_protocols_advertised, protocols}]

        {:preferred_protocols, protocols} ->
          [{:client_preferred_next_protocols, protocols}]
      end)
  end

  @doc """
  Get information about the SSL connection.
  """
  @spec info(t) :: {:ok, list} | {:error, term}
  def info(socket) when socket |> Record.is_record(:sslsocket) do
    :ssl.connection_information(socket)
  end

  @doc """
  Get information about the SSL connection, raising if an error occurs.
  """
  @spec info!(t) :: list | no_return
  defbang(info(socket))

  @doc """
  Get the certificate of the peer.
  """
  @spec certificate(t) :: {:ok, String.t()} | {:error, term}
  def certificate(socket) when socket |> Record.is_record(:sslsocket) do
    :ssl.peercert(socket)
  end

  @doc """
  Get the certificate of the peer, raising if an error occurs.
  """
  @spec certificate!(t) :: String.t() | no_return
  defbang(certificate(socket))

  @doc """
  Get the negotiated protocol.
  """
  @spec negotiated_protocol(t) :: String.t() | nil
  def negotiated_protocol(socket) when socket |> Record.is_record(:sslsocket) do
    case :ssl.negotiated_protocol(socket) do
      {:ok, protocol} ->
        protocol

      {:error, :protocol_not_negotiated} ->
        nil
    end
  end

  @doc """
  Renegotiate the secure connection.
  """
  @spec renegotiate(t) :: :ok | {:error, term}
  def renegotiate(socket) when socket |> Record.is_record(:sslsocket) do
    :ssl.renegotiate(socket)
  end

  @doc """
  Renegotiate the secure connection, raising if an error occurs.
  """
  @spec renegotiate!(t) :: :ok | no_return
  defbang(renegotiate(socket))
end
