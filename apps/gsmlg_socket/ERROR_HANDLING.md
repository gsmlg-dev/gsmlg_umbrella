# Error Handling Guide

This guide provides comprehensive information about error handling in GSMLG.Socket.

## Overview

GSMLG.Socket provides enhanced error handling with:

- **Structured error information** - Categorized errors with context
- **Helpful suggestions** - Actionable debugging steps
- **Retry guidance** - Know which errors are retryable
- **Automatic logging** - Errors logged with full context via GSMLG.Telemetry

## Error Types

### Connection Errors

#### Connection Refused (`:econnrefused`)

**Cause:** The remote server is not accepting connections on the specified port.

**Common Scenarios:**
- Server is not running
- Wrong port number
- Firewall blocking connections
- Server not listening on expected interface (e.g., localhost vs 0.0.0.0)

**Example:**
```elixir
case GSMLG.Socket.TCP.connect("localhost", 8080) do
  {:ok, socket} -> {:ok, socket}
  {:error, :econnrefused} ->
    # Server is not running or not listening on port 8080
    {:error, "Server unavailable"}
end
```

**Resolution:**
```bash
# Check if server is running
lsof -i :8080

# Check firewall rules
sudo iptables -L

# Verify server is listening
netstat -an | grep 8080
```

#### Timeout (`:timeout`)

**Cause:** The operation did not complete within the specified timeout period.

**Common Scenarios:**
- Server is slow to respond
- Network congestion
- Server is overloaded
- Timeout value too low

**Example:**
```elixir
# Use custom timeout
case GSMLG.Socket.TCP.connect("slow-server.com", 80, timeout: 30_000) do
  {:ok, socket} -> {:ok, socket}
  {:error, :timeout} ->
    # Increase timeout or check server health
    {:error, "Connection timeout"}
end
```

**Resolution:**
- Increase timeout value for slow connections
- Implement exponential backoff retry
- Check network latency: `ping slow-server.com`
- Monitor server response times

#### Network Unreachable (`:enetunreach`, `:ehostunreach`)

**Cause:** Cannot route packets to the destination network or host.

**Common Scenarios:**
- Network interface is down
- Incorrect routing configuration
- VPN not connected
- Invalid IP address

**Example:**
```elixir
case GSMLG.Socket.TCP.connect("10.0.0.1", 80) do
  {:ok, socket} -> {:ok, socket}
  {:error, :enetunreach} ->
    # Network routing issue
    Logger.error("Cannot reach network - check routing")
    {:error, "Network unreachable"}
end
```

**Resolution:**
```bash
# Check network interfaces
ip addr show

# Check routing table
ip route show

# Test connectivity
ping 10.0.0.1

# Check default gateway
ip route get 10.0.0.1
```

#### DNS Resolution Failed (`:nxdomain`)

**Cause:** The hostname could not be resolved to an IP address.

**Common Scenarios:**
- Domain does not exist
- Typo in hostname
- DNS server issues
- Network DNS configuration problem

**Example:**
```elixir
case GSMLG.Socket.TCP.connect("nonexistent-domain.invalid", 80) do
  {:ok, socket} -> {:ok, socket}
  {:error, :nxdomain} ->
    # DNS resolution failed
    Logger.error("Invalid hostname")
    {:error, "Domain does not exist"}
end
```

**Resolution:**
```bash
# Test DNS resolution
nslookup nonexistent-domain.invalid

# Check DNS configuration
cat /etc/resolv.conf

# Try alternative DNS server
nslookup nonexistent-domain.invalid 8.8.8.8

# Use IP address instead of hostname
```

### SSL/TLS Errors

#### Handshake Failure (`{:tls_alert, {:handshake_failure, ...}}`)

**Cause:** SSL/TLS handshake could not be completed.

**Common Scenarios:**
- Incompatible TLS versions
- No matching cipher suites
- Server requires client certificate
- Protocol version mismatch

**Example:**
```elixir
case GSMLG.Socket.SSL.connect("old-server.com", 443) do
  {:ok, socket} -> {:ok, socket}
  {:error, {:tls_alert, {:handshake_failure, _}}} ->
    # Try with different TLS versions
    GSMLG.Socket.SSL.connect("old-server.com", 443,
      versions: [:"tlsv1.2", :"tlsv1.1"]
    )
end
```

**Resolution:**
- Check server TLS configuration: `openssl s_client -connect server.com:443`
- Try different TLS versions (server may not support TLS 1.3)
- Review cipher suite compatibility
- Check if client certificate is required

#### Certificate Errors

**Bad Certificate (`{:tls_alert, {:bad_certificate, ...}}`)**

**Cause:** The certificate is malformed, corrupted, or invalid.

**Example:**
```elixir
case GSMLG.Socket.SSL.connect("example.com", 443) do
  {:ok, socket} -> {:ok, socket}
  {:error, {:tls_alert, {:bad_certificate, _}}} ->
    Logger.error("Server certificate is invalid")
    {:error, "Invalid server certificate"}
end
```

**Resolution:**
- Check certificate file integrity
- Verify certificate format (PEM vs DER)
- Check certificate chain completeness
- Regenerate certificate if corrupted

**Certificate Expired (`{:tls_alert, {:certificate_expired, ...}}`)**

**Cause:** The server's certificate has expired.

**Example:**
```elixir
case GSMLG.Socket.SSL.connect("expired-cert.com", 443) do
  {:ok, socket} -> {:ok, socket}
  {:error, {:tls_alert, {:certificate_expired, _}}} ->
    Logger.error("Server certificate expired")
    {:error, "Certificate expired"}
end
```

**Resolution:**
```bash
# Check certificate expiration
openssl s_client -connect expired-cert.com:443 | openssl x509 -noout -dates

# Verify system clock
date

# Check certificate details
openssl s_client -connect expired-cert.com:443 -showcerts
```

**Certificate Unknown (`{:tls_alert, {:certificate_unknown, ...}}`)**

**Cause:** Certificate cannot be verified with available CA certificates.

**Example:**
```elixir
# Provide CA certificate bundle
case GSMLG.Socket.SSL.connect("self-signed.com", 443,
  authorities: [path: "/etc/ssl/certs/ca-bundle.crt"]
) do
  {:ok, socket} -> {:ok, socket}
  {:error, {:tls_alert, {:certificate_unknown, _}}} ->
    Logger.error("Cannot verify certificate")
    {:error, "Certificate verification failed"}
end
```

**Resolution:**
- Update CA certificate bundle
- Add custom CA if using self-signed certificates
- Check certificate chain
- Verify certificate is for correct domain (SNI)

### WebSocket Errors

#### Protocol Error (`:protocol_error`)

**Cause:** Received an invalid WebSocket frame.

**Example:**
```elixir
case GSMLG.Socket.Web.recv(websocket) do
  {:ok, packet} -> {:ok, packet}
  {:error, :protocol_error} ->
    Logger.error("Invalid WebSocket frame received")
    GSMLG.Socket.Web.close(websocket, :protocol_error)
end
```

**Resolution:**
- Check WebSocket frame format
- Verify protocol version compatibility
- Review client/server implementation
- Check for data corruption

#### Invalid Payload (`:invalid_payload`)

**Cause:** WebSocket text frame contains invalid UTF-8.

**Example:**
```elixir
# Use binary frames for non-text data
GSMLG.Socket.Web.send!(websocket, {:binary, binary_data})

# Validate text before sending
if String.valid?(text) do
  GSMLG.Socket.Web.send!(websocket, {:text, text})
else
  Logger.error("Invalid UTF-8 in text frame")
end
```

**Resolution:**
- Verify text frames contain valid UTF-8
- Use binary frames for non-text data
- Validate data encoding before sending

## Error Handling Patterns

### Pattern 1: Simple Retry

```elixir
defp connect_with_retry(host, port, retries \\ 3) do
  case GSMLG.Socket.TCP.connect(host, port) do
    {:ok, socket} ->
      {:ok, socket}

    {:error, reason} when retries > 0 ->
      error_info = GSMLG.Socket.Errors.categorize(reason, :tcp)

      if error_info.retryable do
        Logger.warning("Connection failed, retrying... (#{retries} attempts left)")
        Process.sleep(1000)
        connect_with_retry(host, port, retries - 1)
      else
        Logger.error(GSMLG.Socket.Errors.format(error_info))
        {:error, error_info}
      end

    {:error, reason} ->
      error_info = GSMLG.Socket.Errors.categorize(reason, :tcp)
      Logger.error(GSMLG.Socket.Errors.format(error_info))
      {:error, error_info}
  end
end
```

### Pattern 2: Exponential Backoff

```elixir
defp connect_with_backoff(host, port, attempt \\ 1, max_attempts \\ 5) do
  case GSMLG.Socket.TCP.connect(host, port) do
    {:ok, socket} ->
      {:ok, socket}

    {:error, reason} when attempt < max_attempts ->
      error_info = GSMLG.Socket.Errors.categorize(reason, :tcp)

      if error_info.retryable do
        backoff_ms = :math.pow(2, attempt) * 1000 |> round()
        Logger.warning("Retrying in #{backoff_ms}ms (attempt #{attempt}/#{max_attempts})")
        Process.sleep(backoff_ms)
        connect_with_backoff(host, port, attempt + 1, max_attempts)
      else
        Logger.error(GSMLG.Socket.Errors.format(error_info))
        {:error, error_info}
      end

    {:error, reason} ->
      error_info = GSMLG.Socket.Errors.categorize(reason, :tcp)
      Logger.error("Max retry attempts reached: #{error_info.message}")
      {:error, error_info}
  end
end
```

### Pattern 3: Circuit Breaker

```elixir
defmodule MyApp.ConnectionPool do
  use GenServer

  defstruct [:host, :port, :failures, :last_failure, :state]

  # :closed - accepting connections
  # :open - circuit is open, rejecting connections
  # :half_open - testing if service recovered

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def connect do
    GenServer.call(__MODULE__, :connect)
  end

  def init(opts) do
    state = %__MODULE__{
      host: opts[:host],
      port: opts[:port],
      failures: 0,
      last_failure: nil,
      state: :closed
    }

    {:ok, state}
  end

  def handle_call(:connect, _from, %{state: :open} = state) do
    # Circuit is open, check if enough time has passed
    if circuit_should_attempt?(state) do
      # Try half-open state
      attempt_connection(%{state | state: :half_open})
    else
      {:reply, {:error, :circuit_open}, state}
    end
  end

  def handle_call(:connect, _from, state) do
    attempt_connection(state)
  end

  defp attempt_connection(state) do
    case GSMLG.Socket.TCP.connect(state.host, state.port) do
      {:ok, socket} ->
        # Success - reset circuit
        {:reply, {:ok, socket}, %{state | failures: 0, state: :closed}}

      {:error, reason} ->
        error_info = GSMLG.Socket.Errors.categorize(reason, :tcp)

        if error_info.retryable do
          # Increment failures
          new_state = %{
            state
            | failures: state.failures + 1,
              last_failure: System.monotonic_time()
          }

          # Open circuit if threshold reached
          new_state =
            if new_state.failures >= 5 do
              Logger.error("Circuit opened after #{new_state.failures} failures")
              %{new_state | state: :open}
            else
              new_state
            end

          {:reply, {:error, error_info}, new_state}
        else
          # Non-retryable error, don't affect circuit
          {:reply, {:error, error_info}, state}
        end
    end
  end

  defp circuit_should_attempt?(state) do
    # Wait 30 seconds before trying again
    time_since_failure = System.monotonic_time() - state.last_failure
    time_since_failure > System.convert_time_unit(30, :second, :native)
  end
end
```

### Pattern 4: Fallback with Alternative

```elixir
defp connect_with_fallback(primary_host, fallback_host, port) do
  case GSMLG.Socket.TCP.connect(primary_host, port, timeout: 5000) do
    {:ok, socket} ->
      {:ok, socket}

    {:error, reason} ->
      error_info = GSMLG.Socket.Errors.categorize(reason, :tcp)
      Logger.warning("Primary connection failed: #{error_info.message}, trying fallback...")

      case GSMLG.Socket.TCP.connect(fallback_host, port, timeout: 5000) do
        {:ok, socket} ->
          Logger.info("Connected to fallback host")
          {:ok, socket}

        {:error, fallback_reason} ->
          fallback_error = GSMLG.Socket.Errors.categorize(fallback_reason, :tcp)
          Logger.error("Both primary and fallback failed")
          {:error, %{primary: error_info, fallback: fallback_error}}
      end
  end
end
```

## Using Error Categories

```elixir
case GSMLG.Socket.SSL.connect("example.com", 443) do
  {:ok, socket} ->
    {:ok, socket}

  {:error, reason} ->
    error_info = GSMLG.Socket.Errors.categorize(reason, :ssl)

    case error_info.category do
      :timeout ->
        # Retry with longer timeout
        GSMLG.Socket.SSL.connect("example.com", 443, timeout: 30_000)

      :certificate_error ->
        # Certificate issue - don't retry
        Logger.error("Certificate validation failed")
        send_alert_to_ops_team(error_info)
        {:error, error_info}

      :ssl_error ->
        # TLS configuration issue
        Logger.error("SSL/TLS error: #{error_info.message}")
        {:error, error_info}

      _ ->
        # Unknown or other error
        Logger.error(GSMLG.Socket.Errors.format(error_info))
        {:error, error_info}
    end
end
```

## Best Practices

### 1. Always Check Retryability

```elixir
if GSMLG.Socket.Errors.retryable?(reason, socket_type) do
  # Implement retry logic
else
  # Handle permanent failure
end
```

### 2. Use Structured Logging

```elixir
error_info = GSMLG.Socket.Errors.categorize(reason, :tcp)

Logger.error("Connection failed",
  host: host,
  port: port,
  error_category: error_info.category,
  retryable: error_info.retryable,
  message: error_info.message
)
```

### 3. Provide User-Friendly Messages

```elixir
def friendly_error_message(error_info) do
  case error_info.category do
    :connection_refused ->
      "Unable to connect to the server. Please try again later."

    :timeout ->
      "The server is taking too long to respond. Please check your connection."

    :certificate_error ->
      "Security certificate validation failed. Please contact support."

    _ ->
      "An unexpected error occurred. Please try again."
  end
end
```

### 4. Monitor Error Patterns

```elixir
# Track errors in production
:telemetry.attach(
  "socket-error-tracker",
  [:gsmlg, :socket, :error],
  &MyApp.Metrics.track_socket_error/4,
  nil
)

defmodule MyApp.Metrics do
  def track_socket_error(_event, _measurements, metadata, _config) do
    # Increment error counter by category
    :telemetry.execute(
      [:myapp, :socket, :error, metadata.error_category],
      %{count: 1},
      metadata
    )
  end
end
```

## See Also

- [Telemetry Guide](./TELEMETRY.md)
- [API Documentation](https://hexdocs.pm/gsmlg_socket)
- [GSMLG.Socket.Errors Module](lib/gsmlg/socket/errors.ex)
