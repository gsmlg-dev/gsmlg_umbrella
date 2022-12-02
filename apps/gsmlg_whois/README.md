# GSMLG.Whois

## Intro

Lookup whois information, support IP, ASN and Domain.

```elixir
{:ok, %GSMLG.Whois.Record{}} = GSMLG.Whois.lookup("apple.com")

{:ok, output} = GSMLG.Whois.lookup_raw("apple.com")

{:ok, output} = GSMLG.Whois.lookup_ip_raw("8.8.8.8")

{:ok, output} = GSMLG.Whois.lookup_as_raw("13335")
```

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `gsmlg_whois` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:gsmlg_whois, "~> 1.0.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/gsmlg_whois>.

