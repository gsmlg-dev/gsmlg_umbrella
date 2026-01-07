defmodule GSMLG.CommanderTest.Client.AgentConnection do
  @moduledoc """
  WebSocket connection handler for test agents.

  Uses WebSockex to maintain a WebSocket connection to the Commander server.
  Handles:
  - Connection establishment
  - Frame sending/receiving
  - Heartbeat management
  - Reconnection logic

  """

  use WebSockex

  require Logger

  defstruct [:url, :token, :parent, :connected]

  @doc """
  Connect to the Commander server.

  ## Parameters

    * `url` - WebSocket URL
    * `token` - Authentication token
    * `parent` - Parent process to receive messages

  """
  @spec connect(String.t(), String.t(), pid()) :: {:ok, pid()} | {:error, term()}
  def connect(url, token, parent) do
    state = %__MODULE__{
      url: url,
      token: token,
      parent: parent,
      connected: false
    }

    # Add token to URL as query parameter
    url_with_token = "#{url}?token=#{URI.encode_www_form(token)}"

    case WebSockex.start_link(url_with_token, __MODULE__, state) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Disconnect from the server.
  """
  @spec disconnect(pid()) :: :ok
  def disconnect(pid) do
    WebSockex.cast(pid, :disconnect)
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
    WebSockex.cast(pid, {:send_frame, message})
  end

  # WebSockex callbacks

  @impl true
  def handle_connect(_conn, state) do
    # Send authentication message
    auth_message = %{
      type: "auth",
      token: state.token,
      capabilities: [:shell, :files, :processes, :system_info],
      hostname: hostname()
    }

    frame = {:text, Jason.encode!(auth_message)}
    {:reply, frame, %{state | connected: true}}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, message} ->
        send(state.parent, {:ws_message, message})
        {:ok, state}

      {:error, _reason} ->
        Logger.warning("Failed to decode WebSocket message: #{msg}")
        {:ok, state}
    end
  end

  @impl true
  def handle_frame({:binary, _data}, state) do
    # Handle binary frames if needed
    {:ok, state}
  end

  @impl true
  def handle_cast({:send_frame, message}, state) do
    frame = {:text, Jason.encode!(message)}
    {:reply, frame, state}
  end

  @impl true
  def handle_cast(:disconnect, state) do
    {:close, state}
  end

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    send(state.parent, {:ws_disconnected, reason})
    {:ok, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  # Private helpers

  defp hostname do
    {:ok, hostname} = :inet.gethostname()
    to_string(hostname)
  end
end
