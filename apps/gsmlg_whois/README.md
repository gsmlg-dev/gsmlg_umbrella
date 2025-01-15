# GSMLG.Whois

## Intro

Lookup whois information, support IP, ASN and Domain.

```elixir
{:ok, list} = GSMLG.Whois.lookup_raw("apple.com")

{:ok, list} = GSMLG.Whois.lookup_raw("8.8.8.8")

{:ok, list} = GSMLG.Whois.lookup_raw("13335")

for {whois_server, whois_info} <- list do
  IO.puts "Whois Server #{whois_server}"
  IO.puts whois_info
end
```

## Installation

The package can be installed by adding `gsmlg_whois` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:gsmlg_whois, "~> 0.5.0"}
  ]
end
```
