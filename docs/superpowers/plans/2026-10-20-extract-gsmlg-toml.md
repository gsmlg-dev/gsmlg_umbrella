# Extract gsmlg_toml Implementation Plan

> **For agentic workers:** Use subagent-driven-development for independent work.
> Parent owns source, dependency integration and shared-build validation;
> documentation updates may run in parallel.

**Goal:** Maintain the reusable TOML parser in `apps/gsmlg_toml`, consumed by
`gsmlg_config` through `{:gsmlg_toml, in_umbrella: true}`.

**Architecture:** The parser is an umbrella application with shared
`../../_build`, `../../deps`, `../../mix.lock` and `../../config/config.exs`
paths. It has no runtime or umbrella application dependencies and remains
independently Hex-buildable for external `{:gsmlg_toml, "~> 1.0"}` consumers.
Version remains 1.0.0; no Hex publication, umbrella release or deployment.

**Tech Stack:** Elixir 1.18 / OTP 28 for validation, Mix/Hex, ExUnit, Jason in tests.

## Current correction: source belongs in apps/gsmlg_toml

The user corrected the initial outside-umbrella layout. Parent owns the
following implementation and verification checklist:

- [x] Move the complete parser package from `packages/gsmlg_toml` to
  `apps/gsmlg_toml`, preserving parser and fixture bytes and license notices.
- [x] Use standard umbrella Mix build, configuration, dependency and root
  lockfile paths; remove the package-local lockfile and competing root Hex
  parser entry. Keep Jason test-only and preserve zero runtime dependencies.
- [x] Change `gsmlg_config` to `{:gsmlg_toml, in_umbrella: true}` and update its
  module ownership regression for the internal dependency.
- [x] Update current documentation and source links for the corrected layout;
  retain the 2025 configuration migration instructions as explicitly historical.
- [x] Run scoped parser checks from `apps/gsmlg_toml`:
  `mix test --no-start`, `mix compile --warnings-as-errors`,
  `mix format --check-formatted` and `mix hex.build`.
- [x] Run scoped `gsmlg_config` checks, including
  `mix test --no-start --include config_loading`.
- [x] Validate the corrected archive with an external consumer and verify
  `Toml`/`Toml.Provider` application ownership, no duplicate definitions,
  scoped formatting and `git diff --check`.
- [x] Record corrected-layout results, final source location and publication status.

## Corrected-layout validation

- Scoped parser tests from `apps/gsmlg_toml`: 317 tests, zero failures.
- Scoped configuration tests with `--no-start --include config_loading`:
  133 tests, zero failures.
- Both applications pass `MIX_ENV=test mix compile --force --warnings-as-errors`
  and scoped formatting checks. Configuration dependency inspection resolves
  the parser to `apps/gsmlg_toml`; parser and provider ownership is `:gsmlg_toml`.
- Every parser source, test and fixture file is byte-identical to the previous
  package. The root lockfile no longer contains an external parser entry.
- `mix hex.build` succeeds with no runtime requirements. Corrected archive
  SHA-256: `cf0a1ac78b22390f7087f564964cee5049aeb0b43332367bf8f4df17de90f919`.
- Five tests pass in a fresh consumer of the corrected archive with compiler
  warnings treated as errors. Its production release boots and loads TOML
  through `Toml.Provider`, without umbrella applications. Logs and archive:
  `/tmp/gsmlg-toml-apps-consumer-5c0kkjtz`.
- Read-only correction review found no duplicate definitions, unrelated
  changes or stale active source references. `git diff --check` passes.
- Validation used Elixir 1.18.5 / OTP 28. No new Hex publication, umbrella
  release or deployment occurred.

## Historical implementation and validation before the correction

The initial implementation used `packages/gsmlg_toml` outside `apps/`, default
local Mix paths and a package-local Jason lockfile. `gsmlg_config` consumed the
existing Hex 1.0.0 release. This layout was superseded by the user correction.

The following results are retained as historical evidence:

- Before extraction, the Hex 1.0.0 archive and embedded parser had identical
  executable code; only provider documentation differed.
- Baseline scoped `gsmlg_config` tests:
  `cd apps/gsmlg_config && mix test --no-start --include config_loading`:
  132 tests, zero failures.
- All ten parser source files were copied without byte changes. Historical
  tests and fixtures were restored from `887db246^`: decoding, errors, lexer,
  transforms, provider, 108 valid/55 invalid fixtures and 69 valid/58 invalid
  adapted conformance fixtures.
- Initial outside-umbrella package validation: 317 tests, zero failures;
  strict compile, formatting and Hex build passed. Merged-main validation at
  `379666e9da8809403a68a8ac024bf189ce47d277` also passed 317 tests, zero failures,
  strict compilation and formatting in the original `packages/` layout.
- The consumer ownership regression failed before the original switch because
  `gsmlg_toml.app` could not be found. After switching to Hex 1.0.0, scoped
  `gsmlg_config` validation passed 133 tests, zero failures, strict compilation
  and formatting.
- Five fresh archive consumer tests passed with compiler warnings treated as
  errors. A production consumer release booted and read TOML with `Toml.Provider`.
- The initial archive SHA-256 was
  `80c53fe88211a96e36f57608c36dc2464739dee92b02051bb83dd160e5d5b26f`.
  Historical consumer and release logs: `/tmp/gsmlg-toml-consumer-o6ra91km`.
- Original spec and code-quality reviews passed. Fixture bytes were preserved
  with package-local Git attributes; parser sources were unchanged renames.
- Execution platform: Elixir 1.18.5 / OTP 28. Elixir 1.14 was not executed.
- Existing logger unused-function warnings and telemetry `:warn` deprecation
  appeared before and after the original consumer switch, outside this change.
- No new Hex version, remote package publication, umbrella release or deployment
  occurred during the initial extraction.
