# GSMLG.MAC

## Usage

```elixir
iex> GSMLG.MAC.lookup_vendor("00:00:0A:BB:28:FC")
#=> {:ok, "OmronTat", "Omron Tateisi Electronics Co."}
```

## Update database

```bash
curl -sSLf https://gitlab.com/wireshark/wireshark/-/raw/master/manuf -o priv/manuf
```

## Installation

This package can be installed by adding `gsmlg_mac` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:gsmlg_mac, "~> 0.1.0"}
  ]
end
```

## Documentation

Documentation can be found at <https://hexdocs.pm/gsmlg_mac>.

