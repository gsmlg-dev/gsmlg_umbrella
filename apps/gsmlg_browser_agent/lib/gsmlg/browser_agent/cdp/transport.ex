defmodule GSMLG.BrowserAgent.CDP.Transport do
  @moduledoc false

  @callback connect(String.t(), [{String.t(), String.t()}], pid(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback send(term(), binary()) :: :ok | {:error, term()}
  @callback close(term()) :: :ok | {:error, term()}
end

defmodule GSMLG.BrowserAgent.CDP.Transport.HTTPWebSocket do
  @moduledoc false

  use GenServer

  import Kernel, except: [send: 2]

  @behaviour GSMLG.BrowserAgent.CDP.Transport

  require Mint.HTTP

  @derive {Inspect, except: [:path, :headers, :conn, :websocket]}
  defstruct [
    :owner,
    :owner_monitor,
    :scheme,
    :host,
    :port,
    :path,
    :headers,
    :conn,
    :request_ref,
    :websocket,
    :close_timer,
    closing?: false,
    connect_timeout: 2_000,
    handshake_timeout: 5_000,
    max_message_bytes: 1_048_576,
    max_send_queue_bytes: 1_048_576
  ]

  @call_timeout 5_000

  # WORKAROUND(upstream): gsmlg-dev/http_fetch#13
  # HTTP.WebSocket emits the complete CDP target URL in telemetry metadata. Keep the
  # authenticated target private by owning Mint's process-less connection directly.

  @impl true
  def connect(url, headers, owner, opts)
      when is_binary(url) and is_list(headers) and is_pid(owner) and is_list(opts) do
    with {:ok, target} <- parse_target(url),
         {:ok, limits} <- parse_limits(opts) do
      GenServer.start_link(__MODULE__, {target, headers, owner, limits})
    end
  end

  def connect(_url, _headers, _owner, _opts), do: {:error, :invalid_transport_options}

  @impl true
  def send(socket, payload) when is_pid(socket) and is_binary(payload) do
    GenServer.call(socket, {:send, payload}, @call_timeout)
  catch
    :exit, _reason -> {:error, :closed}
  end

  def send(_socket, _payload), do: {:error, :invalid_payload}

  @impl true
  def close(socket) when is_pid(socket) do
    GenServer.call(socket, :close, @call_timeout)
  catch
    :exit, _reason -> {:error, :closed}
  end

  def close(_socket), do: {:error, :closed}

  @impl true
  def init({target, headers, owner, limits}) do
    {:ok,
     struct!(__MODULE__,
       owner: owner,
       owner_monitor: Process.monitor(owner),
       scheme: target.scheme,
       host: target.host,
       port: target.port,
       path: target.path,
       headers: headers,
       connect_timeout: limits.connect_timeout,
       handshake_timeout: limits.handshake_timeout,
       max_message_bytes: limits.max_message_bytes,
       max_send_queue_bytes: limits.max_send_queue_bytes
     ), {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case open_connection(state) do
      {:ok, state, initial_data} ->
        emit(state, :open)

        if initial_data == <<>> do
          {:noreply, state}
        else
          case decode_frames(state, initial_data) do
            {:ok, state} -> {:noreply, state}
            {:stop, state} -> {:stop, :normal, state}
          end
        end

      {:error, reason, state} ->
        emit(state, {:error, reason})
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_call({:send, _payload}, _from, %{websocket: nil} = state) do
    {:reply, {:error, :invalid_state}, state}
  end

  def handle_call({:send, _payload}, _from, %{closing?: true} = state) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call({:send, payload}, _from, state)
      when byte_size(payload) > state.max_send_queue_bytes do
    {:stop, :normal, {:error, :send_queue_full}, close_connection(state)}
  end

  def handle_call({:send, payload}, _from, state) do
    case send_frame(state, {:text, payload}) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, state} -> {:stop, :normal, {:error, :closed}, close_connection(state)}
    end
  end

  def handle_call(:close, _from, %{conn: nil} = state) do
    {:stop, :normal, :ok, state}
  end

  def handle_call(:close, _from, %{closing?: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:close, _from, state) do
    case send_frame(state, :close) do
      {:ok, state} ->
        timer = Process.send_after(self(), :close_timeout, state.handshake_timeout)
        {:reply, :ok, %{state | closing?: true, close_timer: timer}}

      {:error, state} ->
        {:stop, :normal, :ok, close_connection(state)}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, owner, _reason}, state)
      when monitor == state.owner_monitor and owner == state.owner do
    {:stop, :normal, state}
  end

  def handle_info(:close_timeout, state) do
    emit(state, {:close, 1_006})
    {:stop, :normal, close_connection(state)}
  end

  def handle_info(message, %{conn: conn} = state) when not is_nil(conn) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        handle_stream_responses(responses, %{state | conn: conn})

      {:error, conn, _reason, responses} ->
        state = %{state | conn: conn}

        case process_responses(responses, state) do
          {:ok, state} -> fail_connection(state, :transport_error)
          {:stop, state} -> {:stop, :normal, state}
        end

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = cancel_timer(state.close_timer)
    _ = close_connection(state)
    :ok
  end

  defp parse_target(url) do
    with {:ok, uri} <- URI.new(url),
         true <- uri.scheme in ["ws", "wss"],
         true <- is_binary(uri.host) and uri.host != "",
         true <- is_nil(uri.userinfo) and is_nil(uri.fragment),
         {:ok, port} <- target_port(uri) do
      {:ok,
       %{
         scheme: String.to_existing_atom(uri.scheme),
         host: uri.host,
         port: port,
         path: request_path(uri)
       }}
    else
      _invalid -> {:error, :invalid_websocket_url}
    end
  end

  defp target_port(%URI{port: port}) when is_integer(port) and port in 1..65_535,
    do: {:ok, port}

  defp target_port(%URI{scheme: "ws", port: nil}), do: {:ok, 80}
  defp target_port(%URI{scheme: "wss", port: nil}), do: {:ok, 443}
  defp target_port(_uri), do: {:error, :invalid_port}

  defp request_path(%URI{path: path, query: nil}), do: path || "/"
  defp request_path(%URI{path: path, query: query}), do: (path || "/") <> "?" <> query

  defp parse_limits(opts) do
    limits = %{
      connect_timeout: Keyword.get(opts, :connect_timeout, 2_000),
      handshake_timeout: Keyword.get(opts, :handshake_timeout, 5_000),
      max_message_bytes: Keyword.fetch!(opts, :max_message_bytes),
      max_send_queue_bytes: Keyword.get(opts, :max_send_queue_bytes, 1_048_576)
    }

    if Enum.all?(limits, fn {_key, value} -> is_integer(value) and value > 0 end) do
      {:ok, limits}
    else
      {:error, :invalid_transport_options}
    end
  end

  defp open_connection(state) do
    http_scheme = if state.scheme == :ws, do: :http, else: :https

    connect_opts = [
      mode: :active,
      protocols: [:http1],
      transport_opts: [timeout: state.connect_timeout, send_timeout: state.connect_timeout]
    ]

    with {:ok, conn} <- Mint.HTTP.connect(http_scheme, state.host, state.port, connect_opts),
         {:ok, conn, request_ref} <-
           Mint.WebSocket.upgrade(state.scheme, conn, state.path, state.headers),
         {:ok, conn, status, response_headers, initial_data} <-
           await_upgrade(
             conn,
             request_ref,
             state.owner_monitor,
             monotonic_milliseconds() + state.handshake_timeout,
             state.max_message_bytes + 14
           ),
         {:ok, conn, websocket} <-
           Mint.WebSocket.new(conn, request_ref, status, response_headers, mode: :active) do
      {conn, buffered_data} = take_connection_buffer(conn)

      case append_initial_data(initial_data, buffered_data, state.max_message_bytes + 14) do
        {:ok, initial_data} ->
          {:ok,
           %{
             state
             | conn: conn,
               request_ref: request_ref,
               websocket: websocket,
               path: nil,
               headers: []
           }, initial_data}

        {:error, reason} ->
          {:error, reason, %{state | conn: conn}}
      end
    else
      {:error, conn, _reason} -> {:error, :connection_failed, %{state | conn: conn}}
      {:error, _reason} -> {:error, :connection_failed, state}
    end
  end

  defp await_upgrade(
         conn,
         request_ref,
         owner_monitor,
         deadline,
         max_initial_bytes,
         status \\ nil,
         headers \\ nil,
         initial_data \\ <<>>
       ) do
    remaining = max(deadline - monotonic_milliseconds(), 0)

    receive do
      message when Mint.HTTP.is_connection_message(conn, message) ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            case collect_upgrade_responses(
                   responses,
                   request_ref,
                   status,
                   headers,
                   initial_data,
                   max_initial_bytes
                 ) do
              {:done, status, headers, initial_data} ->
                {:ok, conn, status, headers, initial_data}

              {:more, status, headers, initial_data} ->
                await_upgrade(
                  conn,
                  request_ref,
                  owner_monitor,
                  deadline,
                  max_initial_bytes,
                  status,
                  headers,
                  initial_data
                )

              {:error, reason} ->
                {:error, conn, reason}
            end

          {:error, conn, reason, _responses} ->
            {:error, conn, reason}

          :unknown ->
            await_upgrade(
              conn,
              request_ref,
              owner_monitor,
              deadline,
              max_initial_bytes,
              status,
              headers,
              initial_data
            )
        end

      {:DOWN, ^owner_monitor, :process, _owner, _reason} ->
        {:error, conn, :owner_down}
    after
      remaining -> {:error, conn, :handshake_timeout}
    end
  end

  defp collect_upgrade_responses(
         responses,
         request_ref,
         status,
         headers,
         initial_data,
         max_initial_bytes
       ) do
    result =
      Enum.reduce_while(responses, {status, headers, initial_data, false}, fn
        {:status, ^request_ref, value}, {_status, headers, data, done?}
        when is_integer(value) ->
          {:cont, {value, headers, data, done?}}

        {:headers, ^request_ref, value}, {status, _headers, data, done?}
        when is_list(value) ->
          {:cont, {status, value, data, done?}}

        {:data, ^request_ref, data}, {status, headers, initial_data, done?}
        when is_binary(data) ->
          case append_initial_data(initial_data, data, max_initial_bytes) do
            {:ok, initial_data} -> {:cont, {status, headers, initial_data, done?}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:done, ^request_ref}, {status, headers, data, _done?} ->
          {:cont, {status, headers, data, true}}

        {:error, ^request_ref, reason}, _acc ->
          {:halt, {:error, reason}}

        _response, acc ->
          {:cont, acc}
      end)

    case result do
      {:error, _reason} = error ->
        error

      {status, headers, data, true} when is_integer(status) and is_list(headers) ->
        {:done, status, headers, data}

      {_status, _headers, _data, true} ->
        {:error, :invalid_handshake}

      {status, headers, data, false} ->
        {:more, status, headers, data}
    end
  end

  defp append_initial_data(existing, data, max_bytes)
       when byte_size(existing) + byte_size(data) <= max_bytes,
       do: {:ok, existing <> data}

  defp append_initial_data(_existing, _data, _max_bytes), do: {:error, :message_too_large}

  defp handle_stream_responses(responses, state) do
    case process_responses(responses, state) do
      {:ok, state} -> {:noreply, state}
      {:stop, state} -> {:stop, :normal, state}
    end
  end

  defp process_responses(responses, state) do
    Enum.reduce_while(responses, {:ok, state}, fn
      {:data, request_ref, data}, {:ok, %{request_ref: request_ref} = state}
      when is_binary(data) ->
        case decode_frames(state, data) do
          {:ok, state} -> {:cont, {:ok, state}}
          {:stop, state} -> {:halt, {:stop, state}}
        end

      {:error, request_ref, _reason}, {:ok, %{request_ref: request_ref} = state} ->
        {:halt, {:stop, emit_error(state, :transport_error)}}

      {:done, request_ref}, {:ok, %{request_ref: request_ref} = state} ->
        emit(state, {:close, 1_006})
        {:halt, {:stop, close_connection(state)}}

      _response, acc ->
        {:cont, acc}
    end)
  end

  defp decode_frames(state, data) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        state = %{state | websocket: websocket}

        if retained_message_bytes(websocket) <= state.max_message_bytes + 14 do
          process_frames(frames, state)
        else
          {:stop, emit_error(state, :message_too_large)}
        end

      {:error, websocket, _reason} ->
        {:stop, emit_error(%{state | websocket: websocket}, :protocol_error)}
    end
  end

  defp process_frames(frames, state) do
    Enum.reduce_while(frames, {:ok, state}, fn
      {:text, payload}, {:ok, state}
      when is_binary(payload) and byte_size(payload) <= state.max_message_bytes ->
        emit(state, {:text, payload})
        {:cont, {:ok, state}}

      {:ping, payload}, {:ok, state} ->
        case send_frame(state, {:pong, payload}) do
          {:ok, state} -> {:cont, {:ok, state}}
          {:error, state} -> {:halt, {:stop, emit_error(state, :transport_error)}}
        end

      {:pong, _payload}, acc ->
        {:cont, acc}

      {:close, code, reason}, {:ok, state} ->
        state = reply_to_close(state, code, reason)
        emit(state, {:close, code || 1_000})
        {:halt, {:stop, close_connection(state)}}

      _unsupported_or_oversized, {:ok, state} ->
        {:halt, {:stop, emit_error(state, :protocol_error)}}
    end)
  end

  defp retained_message_bytes(websocket) do
    buffer_bytes = websocket |> Map.get(:buffer, <<>>) |> safe_byte_size()

    fragment_bytes =
      case Map.get(websocket, :fragment) do
        fragment when is_tuple(fragment) and tuple_size(fragment) >= 4 ->
          fragment |> elem(3) |> safe_byte_size()

        _missing ->
          0
      end

    buffer_bytes + fragment_bytes
  end

  defp safe_byte_size(value) when is_binary(value), do: byte_size(value)
  defp safe_byte_size(_value), do: 0

  defp reply_to_close(%{closing?: true} = state, _code, _reason), do: state

  defp reply_to_close(state, code, reason) when is_integer(code) and is_binary(reason) do
    case send_frame(state, {:close, code, reason}) do
      {:ok, state} -> state
      {:error, state} -> state
    end
  end

  defp reply_to_close(state, _code, _reason) do
    case send_frame(state, :close) do
      {:ok, state} -> state
      {:error, state} -> state
    end
  end

  defp send_frame(state, frame) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
          {:ok, conn} -> {:ok, %{state | conn: conn, websocket: websocket}}
          {:error, conn, _reason} -> {:error, %{state | conn: conn, websocket: websocket}}
        end

      {:error, websocket, _reason} ->
        {:error, %{state | websocket: websocket}}
    end
  end

  defp take_connection_buffer(conn) do
    case Map.get(conn, :buffer) do
      data when is_binary(data) and data != <<>> -> {Map.replace!(conn, :buffer, ""), data}
      _empty_or_unavailable -> {conn, <<>>}
    end
  end

  defp fail_connection(state, reason) do
    state = emit_error(state, reason)
    emit(state, {:close, 1_006})
    {:stop, :normal, close_connection(state)}
  end

  defp emit_error(state, reason) do
    emit(state, {:error, reason})
    state
  end

  defp emit(state, event), do: Kernel.send(state.owner, {:cdp_transport, self(), event})

  defp close_connection(%{conn: nil} = state), do: state

  defp close_connection(state) do
    {:ok, conn} = Mint.HTTP.close(state.conn)
    %{state | conn: conn, websocket: nil}
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    _ = Process.cancel_timer(timer)
    :ok
  end

  defp monotonic_milliseconds, do: System.monotonic_time(:millisecond)
end
