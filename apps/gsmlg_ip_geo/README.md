# GSMLG.IpGeo

IP geolocation lookups using MaxMind DB (MMDB) files from providers such as
DB-IP and MaxMind. Supports IPv4 and IPv6 addresses, normalized location results,
and country-name/code helpers.

## Installation

Add the package to your dependencies:

```elixir
{:gsmlg_ip_geo, "~> 1.0"}
```

The package follows the GSMLG umbrella release version. Inside this repository,
use `{:gsmlg_ip_geo, in_umbrella: true}` instead.

## Database configuration

Database files are not bundled. Configure the MMDB files to load when the
application starts:

```elixir
config :gsmlg_ip_geo,
  databases: %{
    city: "/var/lib/geo/city.mmdb",
    country: "/var/lib/geo/country.mmdb"
  }
```

Without configuration, the application looks for `dbip-city-lite.mmdb` and
`dbip-country-lite.mmdb` in its `priv/data` directory. Database usage is subject
to the provider's terms.

## Usage

```elixir
GSMLG.IpGeo.lookup("8.8.8.8")
GSMLG.IpGeo.country_code("8.8.8.8", :country)
GSMLG.IpGeo.coordinates({8, 8, 8, 8})
GSMLG.IpGeo.list_databases()
```

Lookups return `{:ok, result}` or `{:error, reason}`. Load another database at
runtime with `GSMLG.IpGeo.load_database(:custom, "/path/to/custom.mmdb")`, then
pass `:custom` as the second lookup argument.

## License

MIT; see [LICENSE](LICENSE). This license covers the package code, not third-party
geolocation data.
