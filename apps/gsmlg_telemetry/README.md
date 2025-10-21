# GSMLG.Telemetry

Centralized telemetry and logging for GSMLG applications.

## Overview

GSMLG.Telemetry provides a unified interface for structured logging, custom event emission, span tracking, and metrics collection across your Elixir applications. It replaces direct Logger usage with a more powerful telemetry-based approach that integrates with Phoenix, Ecto, and other libraries.

## Features

- **Structured Logging**: Rich metadata support with configurable formatting
- **Custom Events**: Emit business logic events for tracking and analysis
- **Span Tracking**: Measure operation durations with automatic error handling
- **Metrics Collection**: Built-in aggregation and reporting of key metrics
- **Multiple Backends**: Console, file, and AWS CloudWatch Logs support
- **Phoenix Integration**: Automatic collection of web request metrics
- **Ecto Integration**: Database query performance tracking
- **LiveView Integration**: Client-side interaction metrics

## Installation

Add `gsmlg_telemetry` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:gsmlg_telemetry, "~> 0.1.0", in_umbrella: true}
  ]
end
```

Ensure `gsmlg_telemetry` is started in your application's supervision tree:

```elixir
def start(_type, _args) do
  children = [
    # ... other children
    GSMLG.Telemetry.Application
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

## Basic Usage

### Logging

Replace `Logger` calls with `GSMLG.Telemetry`:

```elixir
# Instead of:
Logger.info("User logged in")

# Use:
GSMLG.Telemetry.info("User logged in", metadata: %{user_id: 123, ip: "1.2.3.4"})

# Or with full control:
GSMLG.Telemetry.log(:info, "Payment processed",
  metadata: %{
    user_id: 123,
    amount: 99.99,
    transaction_id: "txn_123"
  }
)
```

### Custom Events

Emit custom telemetry events for business logic:

```elixir
# Emit a custom event
GSMLG.Telemetry.emit([:my_app, :user, :registered], %{user_id: 123}, %{
  email: "user@example.com",
  source: "web_signup"
})

# The event will be automatically handled by configured backends
```

### Span Tracking

Measure operation durations with automatic error handling:

```elixir
# Simple span
result = GSMLG.Telemetry.span([:my_app, :database, :query], %{query: "SELECT *"}, fn ->
  Database.query("SELECT * FROM users")
end)

# Span with additional metadata
{result, extra_meta} = GSMLG.Telemetry.span_with_metadata(
  [:my_app, :cache, :get],
  %{key: "user:123"},
  fn ->
    case Cache.get("user:123") do
      nil -> {:miss, %{cache_hit: false}, %{count: 0}}
      user -> {:hit, %{cache_hit: true, user_id: user.id}, %{count: 1}}
    end
  end
)
```

### Contextual Logging

Create a logger with pre-bound context:

```elixir
# Create a context logger
logger = GSMLG.Telemetry.Logger.context(%{
  request_id: "req_123",
  user_id: 456,
  module: MyModule
})

# Use the contextual logger
logger.info("Processing started")
logger.error("Processing failed", %{error: "timeout"})
```

## Configuration

Add configuration to your `config/config.exs`:

```elixir
config :gsmlg_telemetry,
  # Minimum log level
  level: :info,

  # Metrics to collect
  metrics: [
    # VM metrics
    [:vm, :memory],
    [:vm, :total_run_queue_lengths],
    # Phoenix metrics
    [:phoenix, :endpoint, :stop],
    [:phoenix, :router_dispatch, :stop],
    # Database metrics
    [:ecto, :repo, :query],
    # Custom app metrics
    [:my_app, :web, :request, :duration],
    [:my_app, :repo, :query, :duration]
  ],

  # Backends configuration
  backends: [
    console: [
      enabled: true,
      colored: true,
      show_events: true,
      show_metrics: true,
      level: :info
    ],
    file: [
      enabled: true,
      path: "logs/my_app.log",
      format: :json, # :json, :ltsv, or :text
      max_file_size: 50 * 1024 * 1024, # 50MB
      max_files: 5,
      compress: true,
      buffer_size: 100,
      flush_interval: 5_000
    ],
    cloudwatch: [
      enabled: false, # Enable in production
      log_group_name: "/my_app/production",
      log_stream_name: "web-server-#{System.get_env("HOSTNAME")}",
      region: "us-east-1",
      buffer_size: 100,
      flush_interval: 5_000,
      # AWS credentials are handled by gsmlg_aws
    ]
  ],

  # Metrics reporting
  report_interval: 60_000, # 1 minute
  max_buffer_size: 1000
```

### Environment-Specific Configuration

**Development (`config/dev.exs`)**:
```elixir
config :gsmlg_telemetry,
  level: :debug,
  backends: [
    console: [
      enabled: true,
      colored: true,
      show_events: true,
      show_metrics: true
    ],
    file: [
      enabled: false
    ],
    cloudwatch: [
      enabled: false
    ]
  ]
```

**Production (`config/prod.exs`)**:
```elixir
config :gsmlg_telemetry,
  level: :info,
  backends: [
    console: [
      enabled: false
    ],
    file: [
      enabled: true,
      path: "/var/log/my_app/app.log",
      format: :json
    ],
    cloudwatch: [
      enabled: true,
      log_group_name: "/my_app/production",
      log_stream_name: "#{node()}",
      buffer_size: 500,
      flush_interval: 10_000
    ]
  ]
```

## Phoenix Integration

Add telemetry handlers to your Phoenix endpoint:

```elixir
# lib/my_app_web/endpoint.ex
defmodule MyAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app

  # Telemetry is automatically attached by GSMLG.Telemetry
  # No additional configuration needed
end
```

Add telemetry configuration to your router:

```elixir
# lib/my_app_web/router.ex
defmodule MyAppWeb.Router do
  use MyAppWeb, :router
  use Phoenix.Router

  # Automatic route telemetry will be captured
end
```

## Ecto Integration

Configure your Ecto repo for telemetry:

```elixir
# lib/my_app/repo.ex
defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.MySQL

  # Telemetry events will be automatically captured
end
```

## LiveView Integration

LiveView events are automatically captured when you use Phoenix LiveView:

```elixir
# LiveView mount and handle_params events are tracked automatically
defmodule MyAppWeb.Live.Dashboard do
  use MyAppWeb, :live_view

  # Telemetry events automatically emitted for:
  # - [:phoenix, :live_view, :mount, :start/stop]
  # - [:phoenix, :live_view, :handle_params, :start/stop]
end
```

## Advanced Usage

### Custom Handlers

Attach custom handlers for specific events:

```elixir
# In your application start
GSMLG.Telemetry.attach_handler(
  :my_custom_handler,
  [:my_app, :business, :event],
  MyCustomHandler,
  %{config: "value"}
)

# Define your handler module
defmodule MyCustomHandler do
  def handle_event(event, measurements, metadata, config) do
    # Custom handling logic
    IO.inspect({event, measurements, metadata, config})
  end
end
```

### Custom Metrics

Define custom metrics in your configuration:

```elixir
config :gsmlg_telemetry,
  metrics: [
    # Use Telemetry.Metrics structs for full control
    Telemetry.Metrics.counter("my_app.custom.count"),
    Telemetry.Metrics.sum("my_app.custom.duration", unit: {:native, :millisecond}),
    Telemetry.Metrics.last_value("my_app.custom.status"),
    Telemetry.Metrics.distribution(
      "my_app.custom.response_time",
      unit: {:native, :millisecond},
      reporter_options: [buckets: [10, 50, 100, 250, 500, 1000]]
    )
  ]
```

### Custom Reporters

Create custom metrics reporters:

```elixir
defmodule MyApp.CustomReporter do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def handle_metrics(event_name, aggregates, raw_events) do
    # Send to external monitoring system
    ExternalMonitoring.send_metrics(event_name, aggregates)
  end

  def handle_report(report) do
    # Handle complete reports
    ExternalMonitoring.send_report(report)
  end
end

# Add to configuration
config :gsmlg_telemetry,
  reporters: %{
    custom: %{
      module: MyApp.CustomReporter,
      opts: [endpoint: "https://monitoring.example.com"]
    }
  }
```

## Migration from Logger

### Simple Replacement

```elixir
# Before
Logger.info("User logged in")
Logger.error("Database error: #{inspect(error)}")

# After
GSMLG.Telemetry.info("User logged in")
GSMLG.Telemetry.error("Database error", metadata: %{error: inspect(error)})
```

### Adding Context

```elixir
# Before
Logger.info("Processing request #{request_id} for user #{user_id}")

# After
GSMLG.Telemetry.info("Processing request", metadata: %{
  request_id: request_id,
  user_id: user_id
})
```

### Performance Tracking

```elixir
# Before
start_time = System.monotonic_time()
result = expensive_operation()
duration = System.monotonic_time() - start_time
Logger.info("Operation completed in #{duration} microseconds")

# After
result = GSMLG.Telemetry.span([:my_app, :operation], %{}, fn ->
  expensive_operation()
end)
# Duration and error handling are automatic
```

## CloudWatch Integration

### Setup

1. Configure AWS credentials via `gsmlg_aws` or environment variables
2. Enable CloudWatch backend in production configuration
3. Set appropriate log group and stream names

### Example CloudWatch Queries

Using CloudWatch Insights:

```sql
-- Find all error events
fields @timestamp, metadata.message, metadata.error
| filter level = "error"
| sort @timestamp desc
| limit 100

-- Calculate average response times
stats avg(measurements.duration) as avg_duration
| filter event_name = "my_app.web.request.duration"
| bin @timestamp 1m

-- Find slow database queries
fields @timestamp, metadata.query, measurements.total_time
| filter event_name = "ecto.repo.query" and measurements.total_time > 1000
| sort measurements.total_time desc
```

## Performance Considerations

- **Async Logging**: All backends use async logging to avoid blocking application code
- **Batching**: File and CloudWatch backends batch events for efficiency
- **Buffer Management**: Configurable buffer sizes prevent memory issues
- **Backpressure**: Failed backend operations don't block the application
- **Resource Usage**: Minimal overhead when telemetry is disabled

## Troubleshooting

### Common Issues

1. **Events not appearing**: Check log levels and backend configuration
2. **CloudWatch errors**: Verify AWS credentials and permissions
3. **Performance issues**: Reduce buffer sizes or flush intervals
4. **Missing metrics**: Ensure event handlers are properly attached

### Debug Mode

Enable debug logging for troubleshooting:

```elixir
config :gsmlg_telemetry,
  level: :debug,
  backends: [
    console: [
      enabled: true,
      show_events: true,
      show_metrics: true
    ]
  ]
```

### Statistics

Check backend statistics:

```elixir
# Get console backend stats
GSMLG.Telemetry.Backends.Console.get_config()

# Get file backend stats
GSMLG.Telemetry.Backends.File.get_stats()

# Get CloudWatch backend stats
GSMLG.Telemetry.Backends.CloudWatch.get_stats()

# Get metrics collector stats
GSMLG.Telemetry.Metrics.get_summary()
```

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a Pull Request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for a list of changes and version history.