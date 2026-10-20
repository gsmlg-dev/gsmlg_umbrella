# gsmlg_toml

A TOML decoder for Elixir with the `Toml` and `Toml.*` APIs. It decodes strings,
files and streams into Elixir maps, supports custom value transforms through
`Toml.Transform`, and supplies the `Toml.Provider` release configuration provider.
It has no runtime dependencies and requires Elixir 1.14 or later.

## Installation

Add the existing Hex release to your application's dependencies:

```elixir
{:gsmlg_toml, "~> 1.0"}
```

The package name is `gsmlg_toml`; its public module remains `Toml`.

## Usage

```elixir
{:ok, %{"database" => %{"port" => 5432}}} =
  Toml.decode("[database]\nport = 5432")

config = Toml.decode_file!("config.toml")
{:ok, config} = Toml.decode_stream(File.stream!("config.toml"))
```

The `decode`, `decode_file` and `decode_stream` functions return `{:ok, map}` or
`{:error, reason}`. Their `!` variants return the map or raise. Keys default to
strings; `keys: :atoms!` accepts only existing atoms, while `keys: :atoms` creates
atoms and should only be used with trusted input. The `transforms` option takes
modules implementing `Toml.Transform`.

TOML date and time values become `Date`, `Time`, `NaiveDateTime` or `DateTime`
values. Arrays become lists and tables become maps. Infinity and NaN values use
`:infinity`, `:negative_infinity`, `:nan` and `:negative_nan` atoms.

To use the release configuration provider:

```elixir
config_providers: [
  {Toml.Provider, path: "/etc/my_app.toml"}
]
```

The provider expects root tables named for applications. See the `Toml.Provider`
and `Toml.Transform` module documentation for options and examples.

## Development in the umbrella

The maintained source and regression suite live in `apps/gsmlg_toml`. This Mix
project uses the standard umbrella paths: `../../_build`, `../../deps`,
`../../mix.lock` and `../../config/config.exs`. Dependencies and configuration
are shared with the umbrella; there is no package-local lockfile.

Run scoped parser checks from the application directory:

```sh
cd apps/gsmlg_toml
HEX_MIRROR=https://repo.hex.pm mix deps.get
mix compile --warnings-as-errors
mix format --check-formatted
mix test --no-start
mix hex.build
```

The parser remains independently Hex-buildable: its archive includes `lib`,
`mix.exs`, `README.md` and `LICENSE`, with no runtime dependencies or umbrella
application dependencies. External applications can consume the Hex package
without the GSMLG umbrella.

Jason is used only by the test suite to compare decoded fixtures with expected
JSON values. Tests cover decoding, errors, lexing, transforms, the provider,
and the historical fixture and adapted `toml-test` suites. These historical
fixtures are regression coverage, not a claim of conformance to every current
TOML specification test.

Within this umbrella, `gsmlg_config` uses `{:gsmlg_toml, in_umbrella: true}` and
retains the GSMLG-specific configuration loader, schema, transforms and setup.
External consumers use `{:gsmlg_toml, "~> 1.0"}` as shown above. The package
version follows the shared root and application version. Each product release
publishes the enabled Hex packages at that same version; source pushes alone
do not publish packages. The 1.x installation example above remains usable for
the existing standalone release. See the repository's release guide for the
shared version policy.

## License and provenance

The parser and historical tests derive from
[bitwalker/toml-elixir](https://github.com/bitwalker/toml-elixir), maintained by
Paul Schoenfelder, under Apache-2.0. The `LICENSE` file retains that upstream
license and the Copyright 2022 Jonathan Gao MIT notice shipped in the original
`gsmlg_toml` 1.0.0 archive. That archive declared Apache-2.0 in its metadata but
contained the MIT text; this source package lists both retained licenses.
The historical conformance fixtures are adapted from
[BurntSushi/toml-test](https://github.com/BurntSushi/toml-test).
