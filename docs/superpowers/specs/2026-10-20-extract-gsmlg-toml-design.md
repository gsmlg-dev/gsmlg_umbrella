# Extract gsmlg_toml

The required boundary is a reusable TOML parser in `apps/gsmlg_toml`, with the
application-specific loader, schema and setup remaining in `gsmlg_config`.
The source belongs in the umbrella's `apps` directory, as corrected by the user.

The extracted parser has the same executable code as Hex `gsmlg_toml` 1.0.0.
Nine of its ten source files are byte-identical; `provider.ex` only changes
documentation examples. No new parser version or publication is required.

## Package boundary

- Maintain one parser source and regression suite under `apps/gsmlg_toml`.
- Preserve the `Toml` and `Toml.*` public APIs and parser behavior.
- Use the standard umbrella Mix paths: `../../_build`, `../../deps`,
  `../../mix.lock` and `../../config/config.exs`. The root lockfile owns test
  dependency resolution; there is no package-local lockfile.
- Keep the parser free of runtime and umbrella application dependencies so its
  Hex archive remains independently buildable and usable by external consumers.
- Retain the upstream Apache-2.0 license and the published fork's MIT notice,
  listing both in package metadata. Preserve historical parser tests and fixtures.
- Declare `{:gsmlg_toml, in_umbrella: true}` in `gsmlg_config`, with no embedded
  parser definitions. Retain business configuration modules and TOML defaults.
- External consumers use `{:gsmlg_toml, "~> 1.0"}`. Keep package version 1.0.0;
  this work does not publish a new Hex artifact, create a remote repository,
  release the umbrella, or deploy the application.

## Acceptance

1. From `apps/gsmlg_toml`, scoped `mix test --no-start`, strict compilation and
   formatting pass using the umbrella paths.
2. The parser's Hex archive builds and works in a fresh consumer without
   umbrella applications.
3. `gsmlg_config` uses the internal umbrella dependency and passes scoped tests.
4. The parser and provider belong to `:gsmlg_toml`, with no duplicate definitions
   in `gsmlg_config` and no competing Hex parser entry in the root lockfile.
5. User-owned changes remain untouched.

## Historical validation

The initial extraction placed source in `packages/gsmlg_toml` outside the
umbrella and made `gsmlg_config` consume Hex 1.0.0. Its passing evidence is
preserved in the implementation plan as historical evidence. The user corrected
that layout to `apps/gsmlg_toml`. The corrected layout passes 317 parser tests,
133 configuration tests, strict compilation, formatting and Hex build. A fresh
archive consumer passes five tests and boots a release using `Toml.Provider`.
The implementation plan records corrected-layout evidence separately.
