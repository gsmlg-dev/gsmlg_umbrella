# GSMLG.Whois

## Intro

Lookup whois information, support IP, ASN and Domain.

```elixir
{:ok, output} = GSMLG.Whois.lookup_domain_raw("apple.com")

{:ok, output} = GSMLG.Whois.lookup_ip_raw("8.8.8.8")

{:ok, output} = GSMLG.Whois.lookup_as_raw("13335")
```

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `gsmlg_whois` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:gsmlg_whois, "~> 0.2.0"}
  ]
end
```
