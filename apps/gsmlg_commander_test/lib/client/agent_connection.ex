defmodule GSMLG.CommanderTest.Client.AgentConnection do
  @moduledoc """
  WebSocket connection handler for test agents.

  Uses HTTP.WebSocket to maintain a WebSocket connection to the Commander server.
  Handles:
  - Connection establishment
  - Frame sending/receiving
  - Heartbeat management
  - Reconnection logic

  """

  use GenServer

  alias HTTP.WebSocket
  alias HTTP.WebSocket.Event.{Close, Error, Message, Open}

  require Logger

  defstruct [
    :url,
    :token,
    :parent,
    :socket,
    :web_socket_client,
    web_socket_options: [],
    connected: false
  ]

  @capabilities [:shell, :files, :processes, :system_info]

  @doc """
  Connect to the Commander server.

  ## Parameters

    * `url` - WebSocket URL
    * `token` - Authentication token
    * `parent` - Parent process to receive messages

  """
  @spec connect(String.t(), String.t(), pid()) :: {:ok, pid()} | {:error, term()}
  @spec connect(String.t(), String.t(), pid(), keyword()) :: {:ok, pid()} | {:error, term()}
  def connect(url, token, parent, opts \\ []) do
    state = %__MODULE__{
      url: url_with_token(url, token),
      token: token,
      parent: parent,
      web_socket_client: Keyword.get(opts, :web_socket_client, WebSocket),
      web_socket_options: Keyword.get(opts, :web_socket_options, []),
      connected: false
    }

    GenServer.start_link(__MODULE__, state)
  end

  @doc """
  Disconnect from the server.
  """
  @spec disconnect(pid()) :: :ok
  def disconnect(pid) do
    GenServer.cast(pid, :disconnect)
  end

  @doc """
  Send PTY output to the server.
  """
  @spec send_pty_output(pid(), String.t(), binary()) :: :ok
  def send_pty_output(pid, pty_id, data) do
    message = %{
      type: "pty_output",
      pty_id: pty_id,
      data: Base.encode64(data)
    }

    send_frame(pid, message)
  end

  @doc """
  Send heartbeat response.
  """
  @spec send_heartbeat_response(pid()) :: :ok
  def send_heartbeat_response(pid) do
    message = %{type: "heartbeat_response"}
    send_frame(pid, message)
  end

  @doc """
  Send a JSON frame to the server.
  """
  @spec send_frame(pid(), map()) :: :ok
  def send_frame(pid, message) do
    GenServer.cast(pid, {:send_frame, message})
  end

  # GenServer callbacks

  @impl true
  def init(state) do
    options = Keyword.put(state.web_socket_options, :owner, self())

    case state.web_socket_client.new(state.url, [], options) do
      {:error, reason} -> {:stop, reason}
      socket -> {:ok, %{state | socket: socket}}
    end
  end

  @impl true
  def handle_info({WebSocket, _socket, %Open{}}, state) do
    :ok = send_json(state, auth_message(state))
    {:noreply, %{state | connected: true}}
  end

  def handle_info({WebSocket, _socket, %Message{data: msg}}, state) when is_binary(msg) do
    case Jason.decode(msg) do
      {:ok, message} ->
        send(state.parent, {:ws_message, message})
        {:noreply, state}

      {:error, _reason} ->
        Logger.warning("Failed to decode WebSocket message: #{msg}")
        {:noreply, state}
    end
  end

  def handle_info({WebSocket, _socket, %Message{}}, state) do
    {:noreply, state}
  end

  def handle_info({WebSocket, _socket, %Error{reason: reason}}, state) do
    Logger.warning("WebSocket error: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info({WebSocket, _socket, %Close{} = event}, state) do
    send(state.parent, {:ws_disconnected, disconnect_reason(event)})
    {:noreply, %{state | connected: false, socket: nil}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_frame, message}, state) do
    :ok = send_json(state, message)
    {:noreply, state}
  end

  def handle_cast(:disconnect, state) do
    :ok = close_socket(state)
    {:stop, :normal, %{state | connected: false, socket: nil}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.connected do
      :ok = close_socket(state)
    end

    :ok
  end

  # Private helpers

  defp auth_message(state) do
    %{
      type: "auth",
      token: state.token,
      capabilities: @capabilities,
      hostname: hostname()
    }
  end

  defp send_json(%{socket: nil}, _message), do: :ok

  defp send_json(state, message) do
    case state.web_socket_client.send(state.socket, Jason.encode!(message)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to send WebSocket message: #{inspect(reason)}")
        :ok
    end
  end

  defp close_socket(%{socket: nil}), do: :ok

  defp close_socket(state) do
    case state.web_socket_client.close(state.socket) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to close WebSocket connection: #{inspect(reason)}")
        :ok
    end
  end

  defp disconnect_reason(%Close{reason: reason}) when is_binary(reason) and reason != "" do
    reason
  end

  defp disconnect_reason(%Close{code: code}) do
    code
  end

  defp url_with_token(url, token) do
    uri = URI.parse(url)

    query =
      uri.query
      |> decode_query()
      |> Map.put("token", token)
      |> URI.encode_query()

    uri
    |> Map.put(:query, query)
    |> URI.to_string()
  end

  defp decode_query(nil), do: %{}
  defp decode_query(query), do: URI.decode_query(query)

  defp hostname do
    {:ok, hostname} = :inet.gethostname()
    to_string(hostname)
  end
end
