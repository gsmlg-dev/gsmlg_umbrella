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

  alias HTTP.WebSocket
  alias HTTP.WebSocket.Event.{Close, Error, Message, Open}

  @behaviour GSMLG.BrowserAgent.CDP.Transport

  @derive {Inspect, except: [:url, :headers, :websocket]}
  defstruct [
    :owner,
    :owner_monitor,
    :url,
    :headers,
    :websocket,
    :socket_monitor,
    closing?: false,
    pending_sends: %{},
    pending_send_bytes: 0,
    connect_timeout: 2_000,
    handshake_timeout: 5_000,
    max_message_bytes: 1_048_576,
    max_send_queue_bytes: 1_048_576
  ]

  @call_timeout 5_000

  @impl true
  def connect(url, headers, owner, opts)
      when is_binary(url) and is_list(headers) and is_pid(owner) and is_list(opts) do
    with :ok <- validate_target(url),
         {:ok, limits} <- parse_limits(opts) do
      GenServer.start_link(__MODULE__, {url, headers, owner, limits})
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
  def init({url, headers, owner, limits}) do
    state = struct!(__MODULE__, Map.to_list(limits))

    {:ok,
     %{state | owner: owner, owner_monitor: Process.monitor(owner), url: url, headers: headers},
     {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    options = [
      owner: self(),
      headers: state.headers,
      telemetry_url: nil,
      http_version: :http1,
      delivery: :ack,
      max_message_size: state.max_message_bytes,
      max_queue_bytes: state.max_message_bytes + 7,
      max_queue_events: 1,
      max_send_queue: state.max_send_queue_bytes,
      max_send_frames: 64,
      connect_timeout: state.connect_timeout,
      opening_timeout: state.handshake_timeout,
      close_timeout: state.handshake_timeout,
      write_timeout: state.connect_timeout
    ]

    case WebSocket.new(state.url, [], options) do
      %WebSocket{pid: pid} = websocket ->
        {:noreply,
         %{
           state
           | websocket: websocket,
             socket_monitor: Process.monitor(pid),
             url: nil,
             headers: []
         }}

      {:error, _private_reason} ->
        emit(state, {:error, :connection_failed})
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_call({:send, _payload}, _from, %{websocket: nil} = state),
    do: {:reply, {:error, :invalid_state}, state}

  def handle_call({:send, _payload}, _from, %{closing?: true} = state),
    do: {:reply, {:error, :closed}, state}

  def handle_call({:send, payload}, _from, state)
      when byte_size(payload) + state.pending_send_bytes > state.max_send_queue_bytes or
             map_size(state.pending_sends) >= 64 do
    {:stop, :normal, {:error, :send_queue_full}, state}
  end

  def handle_call({:send, payload}, from, state) do
    case WebSocket.send_ack(state.websocket, payload) do
      {:ok, ref} ->
        {:noreply,
         %{
           state
           | pending_sends: Map.put(state.pending_sends, ref, {from, byte_size(payload)}),
             pending_send_bytes: state.pending_send_bytes + byte_size(payload)
         }}

      {:error, :invalid_state} ->
        {:reply, {:error, :invalid_state}, state}

      {:error, :send_queue_full} ->
        {:stop, :normal, {:error, :send_queue_full}, state}

      {:error, _private_reason} ->
        {:stop, :normal, {:error, :closed}, state}
    end
  end

  def handle_call(:close, _from, %{websocket: nil} = state),
    do: {:stop, :normal, :ok, state}

  def handle_call(:close, _from, state) do
    _ = WebSocket.close(state.websocket)
    {:reply, :ok, %{state | closing?: true}}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, owner, _reason}, state)
      when monitor == state.owner_monitor and owner == state.owner,
      do: {:stop, :normal, state}

  def handle_info({:DOWN, monitor, :process, _socket, _reason}, state)
      when monitor == state.socket_monitor do
    emit(state, {:close, 1_006})
    {:stop, :normal, state}
  end

  def handle_info({WebSocket, socket, %Open{}}, %{websocket: socket} = state) do
    emit(state, :open)
    {:noreply, state}
  end

  def handle_info(
        {WebSocket, socket, %Message{data: payload}, ref},
        %{websocket: socket} = state
      )
      when is_binary(payload) and byte_size(payload) <= state.max_message_bytes do
    emit(state, {:text, payload})
    :ok = WebSocket.acknowledge(socket, ref)
    {:noreply, state}
  end

  def handle_info({WebSocket, socket, %Message{}, _ref}, %{websocket: socket} = state) do
    emit(state, {:error, :protocol_error})
    {:stop, :normal, state}
  end

  def handle_info({WebSocket, socket, %Error{}}, %{websocket: socket} = state) do
    emit(state, {:error, :transport_error})
    {:stop, :normal, state}
  end

  def handle_info({WebSocket, socket, %Close{code: code}}, %{websocket: socket} = state) do
    emit(state, {:close, code || 1_000})
    {:stop, :normal, state}
  end

  def handle_info(
        {WebSocket, socket, {:send_result, ref, result}},
        %{websocket: socket} = state
      ) do
    {pending, pending_sends} = Map.pop(state.pending_sends, ref)
    reply = if result == :ok, do: :ok, else: {:error, :closed}

    bytes =
      case pending do
        {from, bytes} ->
          GenServer.reply(from, reply)
          bytes

        nil ->
          0
      end

    state = %{
      state
      | pending_sends: pending_sends,
        pending_send_bytes: state.pending_send_bytes - bytes
    }

    if result == :ok, do: {:noreply, state}, else: {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.pending_sends, fn {_ref, {from, _bytes}} ->
      GenServer.reply(from, {:error, :closed})
    end)

    # The client's owner monitor also cancels an in-flight opening when this wrapper exits.
    if state.websocket, do: WebSocket.close(state.websocket)
    :ok
  end

  defp validate_target(url) do
    with {:ok, uri} <- URI.new(url),
         true <- uri.scheme in ["ws", "wss"],
         true <- is_binary(uri.host) and uri.host != "",
         true <- is_nil(uri.userinfo) and is_nil(uri.fragment),
         true <- is_nil(uri.port) or (is_integer(uri.port) and uri.port in 1..65_535) do
      :ok
    else
      _invalid -> {:error, :invalid_websocket_url}
    end
  end

  defp parse_limits(opts) do
    limits = %{
      connect_timeout: Keyword.get(opts, :connect_timeout, 2_000),
      handshake_timeout: Keyword.get(opts, :handshake_timeout, 5_000),
      max_message_bytes: Keyword.get(opts, :max_message_bytes),
      max_send_queue_bytes: Keyword.get(opts, :max_send_queue_bytes, 1_048_576)
    }

    if Enum.all?(limits, fn {_key, value} -> is_integer(value) and value > 0 end),
      do: {:ok, limits},
      else: {:error, :invalid_transport_options}
  end

  defp emit(state, event), do: Kernel.send(state.owner, {:cdp_transport, self(), event})
end
