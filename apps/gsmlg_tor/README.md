# GSMLG.Tor

## Start Tor Server through elixir

Tor will be download from: https://www.torproject.org/download/tor/

Auto download tor to priv dir

Generate torrc and run tor from elixir

Start tor server

# Config

Start tor in application supervisor

```elixir
# set in Application Supervisor
  [
    ...
    {GSMLG.Tor}
  ]
```

Manual start/stop
```
GSMLG.Tor.start()
GSMLG.Tor.stop()
```

Config tor in config.exs

```elixir
config :gsmlg_tor, GSMLG.Tor.Config,
  auto_download: true, # autodownload if tor is not exists
  bin_path: nil, # set tor bin path
  conf_path: nil, # set tor config file path
  conf: nil # if conf_path is not set, use conf as binary content

```
