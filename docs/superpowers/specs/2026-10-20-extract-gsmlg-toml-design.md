# Extract gsmlg_toml

The approved boundary is a reusable TOML parser in `gsmlg_toml`, with the
application-specific loader, schema and setup remaining in `gsmlg_config`.

The embedded parser has the same executable code as Hex `gsmlg_toml` 1.0.0.
Nine of its ten source files are byte-identical; `provider.ex` only changes
documentation examples. The existing Hex release can therefore be consumed
without publishing a new parser version.

## Package boundary

- Restore independently buildable source under `packages/gsmlg_toml`, outside
  the umbrella's `apps` directory. This retains one maintained parser source
  without making an umbrella child compete with the Hex dependency.
- Preserve the `Toml` and `Toml.*` public APIs and parser behavior.
- Use standard standalone Mix paths and no runtime dependencies. Retain the
  upstream Apache-2.0 license and the published fork's MIT notice, and list both
  in package metadata. Recover the historical parser regression suite and fixtures.
- Declare `{:gsmlg_toml, "~> 1.0"}` in `gsmlg_config` and remove its embedded
  parser modules. Retain its business configuration modules and TOML defaults.
- Keep package version 1.0.0. This work does not publish a new Hex artifact,
  create a remote repository, release the umbrella, or deploy the application.

## Acceptance

1. The restored parser builds and passes its regression suite independently.
2. Its Hex archive builds and works in a fresh consumer without umbrella code.
3. `gsmlg_config` resolves Hex 1.0.0 and passes its scoped tests.
4. The parser and provider belong to `:gsmlg_toml`, with no duplicate definitions
   in `gsmlg_config`.
5. User-owned changes in the main checkout remain untouched.
