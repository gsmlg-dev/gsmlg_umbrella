# GSMLG.Socket Telemetry Guide

This guide describes the telemetry events, metrics, and logging provided by GSMLG.Socket.

## Overview

GSMLG.Socket integrates with GSMLG.Telemetry to provide comprehensive observability for socket operations. This includes:

- Connection lifecycle tracking
- Performance metrics
- Security event logging
- Error tracking with categorization
- Debug information

## Configuration

Telemetry is automatically enabled when GSMLG.Telemetry is available. Configure output via GSMLG.Telemetry:

```elixir
# config/config.exs
config :gsmlg_telemetry,
  level: :info,
  backends: [
    console: [enabled: true, colored: true],
    cloudwatch: [enabled: true, log_group_name: "/gsmlg/production"]
  ]
```

## Events

All events include standard metadata:
- `socket_type` - The socket type (:tcp, :ssl, :udp, :websocket)
- `module` - The module emitting the event
- `timestamp` - Event timestamp
- `operation` - The operation being performed

### Connection Events

#### TCP Connection

**Event:** `[:gsmlg, :socket, :tcp, :connect]`

Emitted when a TCP connection is established or fails.

**Metadata:**
```elixir
%{
  socket_type: :tcp,
  host: "example.com",
  port: 80,
  timeout: 5000,
  success: true|false,
  local: "{:ok, {{127, 0, 0, 1}, 12345}}" # if successful
}
```

**Example log output:**
```
[info] Socket connect: tcp host=example.com port=80 success=true
```

#### SSL/TLS Connection

**Event:** `[:gsmlg, :socket, :ssl, :connect]`

Emitted when an SSL/TLS connection is established or fails.

**Metadata:**
```elixir
%{
  socket_type: :ssl,
  host: "example.com",
  port: 443,
  tls_versions: [:"tlsv1.3", :"tlsv1.2"],
  success: true|false,
  ssl_info: %{
    protocol: :"tlsv1.3",
    cipher: {:ecdhe_rsa, :aes_256_gcm, :aead, :sha384},
    sni: "example.com"
  } # if successful
}
```

**Example log output:**
```
[warning] SSL connection established: example.com:443 protocol=tlsv1.3
```

#### WebSocket Connection

**Event:** `[:gsmlg, :socket, :websocket, :connect]`

Emitted when a WebSocket connection is initiated.

**Metadata:**
```elixir
%{
  socket_type: :websocket,
  host: "example.com",
  port: 443,
  path: "/websocket",
  secure: true
}
```

### Security Events

#### SSL Handshake

**Event:** `[:gsmlg, :socket, :ssl, :handshake]`

Emitted during SSL/TLS handshake operations.

**Metadata:**
```elixir
%{
  socket_type: :ssl,
  operation: :handshake,
  timeout: 10000,
  success: true|false
}
```

**Example log output (success):**
```
[warning] SSL handshake completed operation=handshake
```

**Example log output (failure):**
```
[warning] SSL handshake failed: {:tls_alert, {:handshake_failure, ...}}
         reason={:tls_alert, {:handshake_failure, ...}}
         error_type=handshake_failure
```

#### Certificate Validation Failures

**Event:** `[:gsmlg, :socket, :ssl, :verify, :error]`

Emitted when certificate verification fails.

**Metadata:**
```elixir
%{
  socket_type: :ssl,
  host: "example.com",
  port: 443,
  reason: {:tls_alert, {:bad_certificate, ...}},
  error_type: :certificate_error
}
```

### Data Transfer Events

#### Data Sent

**Event:** `[:gsmlg, :socket, :send]`

Emitted when data is sent through a socket.

**Metadata:**
```elixir
%{
  socket_type: :tcp|:ssl|:websocket,
  direction: :send,
  bytes: 1024
}
```

#### Data Received

**Event:** `[:gsmlg, :socket, :recv]`

Emitted when data is received from a socket.

**Metadata:**
```elixir
%{
  socket_type: :tcp|:ssl|:websocket,
  direction: :recv,
  bytes: 2048,
  duration_native: 12345 # System.monotonic_time() units
}
```

#### WebSocket Frame Events

**Event:** `[:gsmlg, :socket, :websocket, :frame, :recv]`

Emitted when a WebSocket frame is received.

**Metadata:**
```elixir
%{
  socket_type: :websocket,
  direction: :recv,
  packet_type: :text|:binary|:ping|:pong|:close,
  duration_native: 12345
}
```

### Error Events

#### Connection Errors

**Event:** `[:gsmlg, :socket, :error, :connection]`

Emitted when a connection error occurs.

**Metadata:**
```elixir
%{
  socket_type: :tcp,
  host: "example.com",
  port: 80,
  reason: :econnrefused,
  error_message: "Connection refused",
  category: :connection_refused,
  retryable: true,
  suggestions: ["Check if the server is running", ...]
}
```

**Example log output:**
```
[error] Socket operation failed: connect
        reason=econnrefused
        error_message="Connection refused"
        suggestions=["Check if the server is running", ...]
```

## Performance Metrics

### Connection Duration

Track connection establishment time using the span functionality:

```elixir
GSMLG.Socket.Telemetry.span(:connect, %{host: "example.com", port: 443}, fn ->
  socket = GSMLG.Socket.SSL.connect!("example.com", 443)
  {socket, %{}}
end)
```

**Metadata includes:**
- `duration` - Time in native units (System.monotonic_time)
- `result` - :ok or :error

### Data Transfer Rate

Monitor bytes sent/received over time using the data transfer events.

## Error Categorization

Errors are automatically categorized to help with debugging:

### Error Categories

- **:connection_refused** - Server not accepting connections (retryable)
- **:timeout** - Operation exceeded time limit (retryable)
- **:network_unreachable** - Network routing issues (retryable)
- **:ssl_error** - SSL/TLS handshake or protocol errors (usually not retryable)
- **:certificate_error** - Certificate validation failures (not retryable)
- **:protocol_error** - WebSocket or other protocol violations (not retryable)
- **:invalid_data** - Malformed data or invalid parameters (not retryable)
- **:unknown** - Unrecognized errors (not retryable)

### Using Error Information

```elixir
case GSMLG.Socket.TCP.connect("example.com", 80) do
  {:ok, socket} ->
    {:ok, socket}

  {:error, reason} ->
    error_info = GSMLG.Socket.Errors.categorize(reason, :tcp)

    if error_info.retryable do
      # Implement retry logic
      Logger.warning("Retrying connection: #{error_info.message}")
      retry_connection()
    else
      # Handle non-retryable error
      Logger.error(GSMLG.Socket.Errors.format(error_info))
      {:error, error_info}
    end
end
```

## Production Monitoring

### CloudWatch Integration

When CloudWatch backend is enabled, all telemetry events are sent to CloudWatch Logs:

```elixir
config :gsmlg_telemetry,
  backends: [
    cloudwatch: [
      enabled: true,
      log_group_name: "/gsmlg/production",
      log_stream_prefix: "socket-",
      batch_size: 100,
      flush_interval_ms: 5000
    ]
  ]
```

### Recommended CloudWatch Metrics

Create metric filters for:

1. **Connection Success Rate**
   - Filter: `{ $.socket_type = * && $.success = true }`
   - Metric: Count of successful connections

2. **SSL/TLS Handshake Failures**
   - Filter: `{ $.operation = "handshake" && $.success = false }`
   - Metric: Count of handshake failures

3. **Connection Errors by Type**
   - Filter: `{ $.error_type = * }`
   - Metric: Count grouped by error_type

4. **WebSocket Frame Rates**
   - Filter: `{ $.socket_type = "websocket" && $.direction = "recv" }`
   - Metric: Count of frames received

### Example Queries

**Find all SSL connection failures:**
```
fields @timestamp, host, port, reason, error_type
| filter socket_type = "ssl" and success = false
| sort @timestamp desc
```

**Calculate average connection time:**
```
fields @timestamp, host, port, duration
| filter operation = "connect" and success = true
| stats avg(duration) by host
```

**Find retryable errors:**
```
fields @timestamp, host, port, error_message, suggestions
| filter retryable = true
| sort @timestamp desc
```

## Best Practices

### 1. Add Context to Operations

Always include relevant metadata when performing socket operations:

```elixir
metadata = %{
  request_id: request_id,
  user_id: user_id,
  correlation_id: correlation_id
}

GSMLG.Socket.Telemetry.span(:connect, Map.merge(connection_info, metadata), fn ->
  # Your connection logic
end)
```

### 2. Handle Errors Appropriately

Use error categorization to determine retry strategy:

```elixir
def connect_with_retry(host, port, max_retries \\ 3) do
  Enum.reduce_while(1..max_retries, nil, fn attempt, _acc ->
    case GSMLG.Socket.TCP.connect(host, port) do
      {:ok, socket} ->
        {:halt, {:ok, socket}}

      {:error, reason} ->
        error_info = GSMLG.Socket.Errors.categorize(reason, :tcp)

        if error_info.retryable and attempt < max_retries do
          Process.sleep(attempt * 1000)
          {:cont, nil}
        else
          {:halt, {:error, error_info}}
        end
    end
  end)
end
```

### 3. Monitor Security Events

Set up alerts for security-related events:

```elixir
# In your monitoring setup
config :gsmlg_telemetry,
  handlers: [
    {MyApp.SecurityAlerts, [:gsmlg, :socket, :ssl, :verify, :error]}
  ]
```

### 4. Track Performance Over Time

Use telemetry metrics to track performance trends:

```elixir
:telemetry.attach(
  "socket-performance",
  [:gsmlg, :socket, :connect, :stop],
  &MyApp.Metrics.handle_socket_metrics/4,
  nil
)
```

## Troubleshooting

### High Connection Failure Rate

Check logs for common error patterns:

```elixir
# Look for connection refused errors
fields @timestamp, host, port, reason
| filter socket_type = "tcp" and reason = "econnrefused"
| stats count() by host, port
```

### SSL/TLS Issues

Review SSL handshake failures:

```elixir
# Check SSL handshake failures
fields @timestamp, host, error_type, suggestions
| filter socket_type = "ssl" and success = false
| sort @timestamp desc
```

### WebSocket Connection Issues

Monitor WebSocket upgrade process:

```elixir
# Track WebSocket upgrades
fields @timestamp, host, path, success
| filter socket_type = "websocket"
| stats count() by success
```

## See Also

- [GSMLG.Telemetry Documentation](../gsmlg_telemetry/README.md)
- [GSMLG.Socket API Documentation](https://hexdocs.pm/gsmlg_socket)
- [Error Handling Guide](./ERROR_HANDLING.md)
