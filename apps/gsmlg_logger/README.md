# GSMLG.Logger

Source is copy from `https://github.com/Nebo15/logger_json`.

Add Fomatter

* `GSMLG.Logger.Formatters.GsmlgNet`

Fix

* remote_ip maybe unix socket format `{:local, ""}`

## Installation

Add `gsmlg_logger` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:gsmlg_logger, "~> 0.1.0"}
  ]
end
```

## Documentation

Documents at [HexDocs](https://hexdocs.pm/gsmlg_logger).

## Usage

Config `logger` in `config.exs`

```elixir
import Config

# set logger
config :logger, :default_handler,
  formatter: {GSMLG.Logger.Formatters.GsmlgNet, metadata: :all, planet: "LLM"}
```

Set `env` `RUN_LEVEL` in `runtime.exs`

```elixir
import Config

# default env var is "LOG_LEVEL"
GSMLG.Logger.configure_log_level_from_env!()
```

Use with `ecto`

```elixir
# Attaching the telemetry handler to the `MyApp.Repo` events with the `:info` log level:
GSMLG.Logger.Ecto.attach("gsmlg-logger-queries", [:my_app, :repo, :query], :info)
```

Use with `plug`

```elixir
# Attaching the telemetry handler to the `MyApp.Plug` events with the `:info` log level:

## in the endpoint
plug Plug.Telemetry, event_prefix: [:myapp, :plug]

## in your application.ex
GSMLG.Logger.Plug.attach("gsmlg-logger-requests", [:myapp, :plug, :stop], :info)
```

Use with `phoenix`

```elixir
# You can also attach to the `[:phoenix, :endpoint, :stop]` event to log request latency from Phoenix endpoints:

GSMLG.Logger.Plug.attach("gsmlg-logger-phoenix-requests", [:phoenix, :endpoint, :stop], :info)
```
