defmodule GSMLG.Socket.Telemetry do
  @moduledoc """
  Telemetry integration for GSMLG.Socket operations.

  This module provides instrumentation for socket operations including:
  - Connection lifecycle events (connect, accept, close)
  - Data transfer metrics (send, recv)
  - Security events (SSL handshake, certificate validation)
  - Error tracking and debugging

  ## Events

  All events are emitted with the prefix `[:gsmlg, :socket]`.

  ### Connection Events

  - `[:gsmlg, :socket, :connect, :start]` - Connection attempt started
  - `[:gsmlg, :socket, :connect, :stop]` - Connection completed (success or failure)
  - `[:gsmlg, :socket, :accept, :start]` - Accept operation started
  - `[:gsmlg, :socket, :accept, :stop]` - Accept operation completed
  - `[:gsmlg, :socket, :close]` - Socket closed

  ### Data Transfer Events

  - `[:gsmlg, :socket, :send, :start]` - Send operation started
  - `[:gsmlg, :socket, :send, :stop]` - Send operation completed
  - `[:gsmlg, :socket, :recv, :start]` - Receive operation started
  - `[:gsmlg, :socket, :recv, :stop]` - Receive operation completed

  ### Security Events

  - `[:gsmlg, :socket, :ssl, :handshake, :start]` - SSL handshake started
  - `[:gsmlg, :socket, :ssl, :handshake, :stop]` - SSL handshake completed
  - `[:gsmlg, :socket, :ssl, :verify, :error]` - Certificate verification failed

  ### WebSocket Events

  - `[:gsmlg, :socket, :websocket, :upgrade, :start]` - WebSocket upgrade started
  - `[:gsmlg, :socket, :websocket, :upgrade, :stop]` - WebSocket upgrade completed
  - `[:gsmlg, :socket, :websocket, :frame, :send]` - WebSocket frame sent
  - `[:gsmlg, :socket, :websocket, :frame, :recv]` - WebSocket frame received

  ## Metadata

  All events include standard metadata:
  - `socket_type` - :tcp, :ssl, :udp, :websocket
  - `module` - The module emitting the event
  - `local_address` - Local endpoint (if available)
  - `remote_address` - Remote endpoint (if available)

  Additional metadata varies by event type.

  ## Example Usage

      # In application code
      GSMLG.Socket.Telemetry.span(:connect, %{host: "example.com", port: 443, type: :ssl}, fn ->
        socket = GSMLG.Socket.SSL.connect!("example.com", 443)
        {socket, %{connection_time: :os.system_time(:millisecond)}}
      end)

  ## Configuration

  Telemetry is always enabled but respects GSMLG.Telemetry configuration for output.
  """

  require GSMLG.Telemetry

  @doc """
  Execute a function within a telemetry span for socket operations.

  ## Parameters

  - `operation` - The operation name (atom)
  - `metadata` - Map of metadata to include in events
  - `fun` - Function to execute, should return {result, additional_metadata}

  ## Returns

  The result from the function.

  ## Example

      GSMLG.Socket.Telemetry.span(:connect, %{host: "example.com", port: 80}, fn ->
        socket = GSMLG.Socket.TCP.connect!("example.com", 80)
        {socket, %{}}
      end)
  """
  @spec span(atom(), map(), function()) :: any()
  def span(operation, metadata, fun) when is_atom(operation) and is_map(metadata) do
    start_time = System.monotonic_time()
    metadata = Map.put(metadata, :operation, operation)

    try do
      result = fun.()

      {return_value, additional_metadata} =
        case result do
          {val, meta} when is_map(meta) -> {val, meta}
          val -> {val, %{}}
        end

      duration = System.monotonic_time() - start_time

      emit_stop(operation, Map.merge(metadata, additional_metadata), %{
        duration: duration,
        result: :ok
      })

      return_value
    rescue
      exception ->
        duration = System.monotonic_time() - start_time

        emit_error(operation, metadata, %{
          duration: duration,
          error: exception.__struct__,
          message: Exception.message(exception),
          stacktrace: __STACKTRACE__
        })

        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        duration = System.monotonic_time() - start_time

        emit_error(operation, metadata, %{
          duration: duration,
          kind: kind,
          reason: reason
        })

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc """
  Log a connection event with security context.
  """
  @spec log_connection(atom(), :connect | :accept | :close, map()) :: :ok
  def log_connection(socket_type, event, metadata \\ %{}) do
    metadata =
      metadata
      |> Map.put(:socket_type, socket_type)
      |> Map.put(:event, event)

    level = if event == :close, do: :debug, else: :info

    GSMLG.Telemetry.log(
      level,
      "Socket #{event}: #{socket_type}",
      metadata: metadata
    )

    :ok
  end

  @doc """
  Log an error event with full context.
  """
  @spec log_error(atom(), String.t(), map()) :: :ok
  def log_error(socket_type, message, metadata \\ %{}) do
    metadata =
      metadata
      |> Map.put(:socket_type, socket_type)
      |> Map.put_new(:module, __MODULE__)

    GSMLG.Telemetry.error(message, metadata: metadata)
    :ok
  end

  @doc """
  Log a security event (SSL/TLS operations).
  """
  @spec log_security(String.t(), map()) :: :ok
  def log_security(message, metadata \\ %{}) do
    metadata =
      metadata
      |> Map.put(:security_event, true)
      |> Map.put_new(:module, __MODULE__)

    GSMLG.Telemetry.warn(message, metadata: metadata)
    :ok
  end

  @doc """
  Log data transfer metrics.
  """
  @spec log_data_transfer(atom(), :send | :recv, non_neg_integer(), map()) :: :ok
  def log_data_transfer(socket_type, direction, bytes, metadata \\ %{}) do
    metadata =
      metadata
      |> Map.put(:socket_type, socket_type)
      |> Map.put(:direction, direction)
      |> Map.put(:bytes, bytes)

    GSMLG.Telemetry.debug("Socket #{direction}: #{bytes} bytes", metadata: metadata)
    :ok
  end

  # Private helper functions

  defp emit_stop(operation, metadata, measurements) do
    GSMLG.Telemetry.info(
      "Socket operation completed: #{operation}",
      metadata: Map.merge(metadata, measurements)
    )
  end

  defp emit_error(operation, metadata, measurements) do
    GSMLG.Telemetry.error(
      "Socket operation failed: #{operation}",
      metadata: Map.merge(metadata, measurements)
    )
  end
end
