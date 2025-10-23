# GSMLG.Socket

A comprehensive Elixir socket library providing unified interfaces for TCP, SSL, UDP, and WebSocket connections. This library wraps Erlang's `:gen_tcp`, `:ssl`, and `:gen_udp` modules while implementing RFC 6455 WebSockets with an idiomatic Elixir API.

## Features

- **Multiple Protocol Support**: TCP, SSL/TLS, UDP, and WebSocket (RFC 6455)
- **Unified API**: Consistent interface across all socket types using Elixir protocols
- **Security First**: TLS 1.2+ enforced by default with secure random key generation
- **Dual API Style**: Both safe `{:ok, result}` and bang `result!` function variants
- **URI-based Connections**: Simple URI string support for common protocols
- **High Performance**: Optimized WebSocket masking using iolists
- **Well-typed**: Comprehensive `@spec` annotations throughout
- **Telemetry Integration**: Built-in observability with GSMLG.Telemetry for production monitoring
- **Enhanced Error Handling**: Structured errors with categorization and actionable suggestions
- **Security Monitoring**: Automatic logging of SSL/TLS events and certificate validation

## Installation

Add `gsmlg_socket` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:gsmlg_socket, "~> 0.1.0"}
  ]
end
```

## Quick Start

### TCP Echo Server

```elixir
# Start a TCP server
{:ok, server} = GSMLG.Socket.TCP.listen(1337)

# Accept a client connection
{:ok, client} = GSMLG.Socket.accept(server)

# Echo received data back
data = GSMLG.Socket.Stream.recv!(client)
GSMLG.Socket.Stream.send!(client, data)

# Clean up
GSMLG.Socket.close(client)
GSMLG.Socket.close(server)
```

### TCP Client

```elixir
# Connect to a server
{:ok, socket} = GSMLG.Socket.TCP.connect("example.com", 80)

# Send an HTTP request
GSMLG.Socket.Stream.send!(socket, "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")

# Receive response
{:ok, response} = GSMLG.Socket.Stream.recv(socket)

GSMLG.Socket.close(socket)
```

### SSL/TLS Connection

```elixir
# Connect with TLS 1.2+ (enforced by default)
{:ok, socket} = GSMLG.Socket.SSL.connect("example.com", 443)

# Or with certificate verification
{:ok, socket} = GSMLG.Socket.SSL.connect("example.com", 443,
  verify: [function: &verify_cert/3],
  authorities: [path: "/path/to/ca-bundle.crt"]
)

GSMLG.Socket.Stream.send!(socket, "GET / HTTP/1.1\r\n...")
```

### WebSocket Client

```elixir
# Connect to WebSocket server
{:ok, ws} = GSMLG.Socket.Web.connect("echo.websocket.org", 80, path: "/")

# Send a text message
GSMLG.Socket.Web.send!(ws, {:text, "Hello, WebSocket!"})

# Receive response
{:ok, {:text, message}} = GSMLG.Socket.Web.recv(ws)

# Clean close
GSMLG.Socket.Web.close(ws, :normal)
```

### WebSocket Server

```elixir
# Listen for WebSocket connections
{:ok, server} = GSMLG.Socket.Web.listen(8080)

# Accept incoming connection
{:ok, client} = GSMLG.Socket.Web.accept(server)

# Inspect headers, origin, path before finalizing
IO.inspect(client.origin)
IO.inspect(client.path)

# Finalize the handshake
GSMLG.Socket.Web.accept!(client)

# Echo messages
{:ok, packet} = GSMLG.Socket.Web.recv(client)
GSMLG.Socket.Web.send!(client, packet)
```

### UDP Sockets

```elixir
# Open UDP socket
{:ok, socket} = GSMLG.Socket.UDP.open(5000)

# Send datagram
GSMLG.Socket.Datagram.send!(socket, "Hello, UDP!", {"192.168.1.100", 5001})

# Receive datagram
{:ok, {data, {address, port}}} = GSMLG.Socket.Datagram.recv(socket)
```

### URI-based Connections

```elixir
# TCP
{:ok, socket} = GSMLG.Socket.connect("tcp://example.com:80")

# SSL
{:ok, socket} = GSMLG.Socket.connect("ssl://example.com:443")

# WebSocket
{:ok, socket} = GSMLG.Socket.connect("ws://example.com:80/path")

# Secure WebSocket
{:ok, socket} = GSMLG.Socket.connect("wss://example.com:443/path")
```

## Protocol Support

### TCP (GSMLG.Socket.TCP)

Full-featured TCP socket implementation with:
- Listening and connecting
- Active, passive, and `:once` modes
- Packet modes (`:line`, `:raw`, etc.)
- Controlling process management
- Send/receive timeouts

### SSL/TLS (GSMLG.Socket.SSL)

Secure socket layer with:
- **TLS 1.2 and 1.3 enforced by default**
- Certificate verification support
- Client and server modes
- SNI (Server Name Indication)
- Custom cipher suites
- Session reuse

### UDP (GSMLG.Socket.UDP)

Datagram protocol support:
- Broadcast support
- Multicast support
- Membership management
- IPv4 and IPv6

### WebSocket (GSMLG.Socket.Web)

RFC 6455 compliant implementation:
- Client and server modes
- Text and binary frames
- Fragmentation support
- Ping/pong heartbeat
- Graceful connection closing
- Extension negotiation
- **Cryptographically secure handshake keys**

## Security

### SSL/TLS Defaults

By default, SSL connections enforce modern security standards:

```elixir
# These are applied automatically:
# - TLS versions: [:tlsv1.3, :tlsv1.2]
# - No SSLv3, TLS 1.0, or TLS 1.1

# Override only if you have specific requirements:
GSMLG.Socket.SSL.connect(host, port, versions: [:"tlsv1.2"])
```

### Certificate Verification

Always verify certificates in production:

```elixir
GSMLG.Socket.SSL.connect("example.com", 443,
  verify: [function: &:ssl_verify_hostname.verify_fun/3, data: [check_hostname: "example.com"]],
  authorities: [path: "/etc/ssl/certs/ca-certificates.crt"]
)
```

### WebSocket Security

- Default handshake keys use `:crypto.strong_rand_bytes/1`
- Masking properly implemented for client messages
- Close codes follow RFC 6455 security recommendations

## Configuration Options

### TCP Options

```elixir
GSMLG.Socket.TCP.listen(port,
  mode: :passive,           # :active, :passive, :once
  as: :binary,              # :binary, :list
  packet: :raw,             # :raw, :line, 0..4, :http
  backlog: 128,
  reuse: true,
  local: [
    address: "0.0.0.0",
    port: 8080
  ],
  send: [
    timeout: 5000,
    buffer: 8192
  ],
  recv: [
    buffer: 8192
  ]
)
```

### SSL Options

```elixir
GSMLG.Socket.SSL.connect(host, port,
  versions: [:"tlsv1.3", :"tlsv1.2"],
  cert: [path: "/path/to/cert.pem"],
  key: [path: "/path/to/key.pem"],
  authorities: [path: "/path/to/ca-bundle.crt"],
  verify: [function: &verify_fn/3],
  server_name: "example.com",
  ciphers: [...],
  depth: 2
)
```

### WebSocket Options

```elixir
GSMLG.Socket.Web.connect(host, port,
  path: "/websocket",
  origin: "https://example.com",
  protocol: ["chat", "superchat"],
  extensions: ["permessage-deflate"],
  headers: %{"Authorization" => "Bearer token"},
  secure: true  # Use SSL/TLS
)
```

## Advanced Usage

### Active Mode Sockets

```elixir
{:ok, socket} = GSMLG.Socket.TCP.listen(port, mode: :active)

receive do
  {:tcp, ^socket, data} ->
    IO.puts("Received: #{data}")
  {:tcp_closed, ^socket} ->
    IO.puts("Connection closed")
  {:tcp_error, ^socket, reason} ->
    IO.puts("Error: #{reason}")
end
```

### Subnet Checking

```elixir
# Check if IP is in subnet
GSMLG.Socket.Address.is_in_subnet?(
  {192, 168, 1, 100},  # address
  {192, 168, 1, 0},    # network
  24                    # CIDR prefix
)
# => true
```

### Address Parsing

```elixir
# Parse IP addresses
GSMLG.Socket.Address.parse("192.168.1.1")
# => {192, 168, 1, 1}

GSMLG.Socket.Address.parse("2001:db8::1")
# => {8193, 3512, 0, 0, 0, 0, 0, 1}

# Validate addresses
GSMLG.Socket.Address.valid?("192.168.1.1")
# => true

# Convert to string
GSMLG.Socket.Address.to_string({192, 168, 1, 1})
# => "192.168.1.1"
```

## Error Handling

GSMLG.Socket provides enhanced error handling with structured error information:

```elixir
case GSMLG.Socket.TCP.connect("example.com", 80) do
  {:ok, socket} ->
    # Handle success
    {:ok, socket}

  {:error, reason} ->
    # Get structured error information
    error_info = GSMLG.Socket.Errors.categorize(reason, :tcp)

    # Check if error is retryable
    if error_info.retryable do
      Logger.warning("Retryable error: #{error_info.message}")
      # Implement retry logic
    else
      # Log error with suggestions
      Logger.error(GSMLG.Socket.Errors.format(error_info))
      {:error, error_info}
    end
end

# Or use bang version to raise on error
socket = GSMLG.Socket.TCP.connect!("example.com", 80)
```

See [Error Handling Guide](ERROR_HANDLING.md) for comprehensive error handling patterns.

## Testing

Run the test suite:

```bash
mix test
```

Run specific test files:

```bash
mix test test/gsmlg/socket/tcp_test.exs
mix test test/gsmlg/socket/ssl_test.exs
mix test test/gsmlg/socket/udp_test.exs
mix test test/gsmlg/socket/web_test.exs
```

## Telemetry and Monitoring

GSMLG.Socket integrates with GSMLG.Telemetry for production observability:

```elixir
# All operations are automatically instrumented
{:ok, socket} = GSMLG.Socket.SSL.connect("api.example.com", 443)

# Events logged include:
# - Connection attempts and results
# - SSL/TLS handshake details
# - Certificate validation
# - Data transfer metrics
# - Error details with categorization

# Configure output via GSMLG.Telemetry
config :gsmlg_telemetry,
  level: :info,
  backends: [
    console: [enabled: true],
    cloudwatch: [enabled: true, log_group_name: "/gsmlg/production"]
  ]
```

See [Telemetry Guide](TELEMETRY.md) for detailed event reference and monitoring strategies.

## Performance

The library is optimized for performance:

- **WebSocket masking** uses iolists for O(n) complexity instead of O(n²)
- **Zero-copy operations** where possible using `:file.sendfile/2`
- **Minimal overhead** wrapping Erlang's battle-tested socket implementations
- **Efficient telemetry** with minimal performance impact

## License

MIT License - See LICENSE file for details.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass
5. Submit a pull request

## Changelog

### 0.1.0 (Current)

- Initial release
- TCP, SSL, UDP, and WebSocket support
- Security enhancements (TLS 1.2+, secure random keys)
- Performance improvements (optimized WebSocket masking)
- Comprehensive test suite
- Full documentation

## Documentation

Full documentation can be generated with ExDoc:

```bash
mix docs
```

Documentation is available at [https://hexdocs.pm/gsmlg_socket](https://hexdocs.pm/gsmlg_socket).

## Support

For issues, questions, or contributions, please visit the [GitHub repository](https://github.com/gsmlg-dev/gsmlg_umbrella).
