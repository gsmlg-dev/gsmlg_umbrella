# Extract gsmlg_toml Implementation Plan

> **For agentic workers:** Use subagent-driven-development for the independent
> package restoration and parent-owned consumer integration.

**Goal:** Maintain a standalone TOML package while consuming its existing Hex
release from `gsmlg_config`.

**Architecture:** `packages/gsmlg_toml` is an independent Mix project outside the
umbrella. `gsmlg_config` uses Hex 1.0.0 and contains only business configuration.

**Tech Stack:** Elixir 1.18 / OTP 28 for validation, Mix/Hex, ExUnit, Jason in tests.

## Task 1: Establish the baseline

- [x] Compare the Hex 1.0.0 archive with the embedded parser: executable code is
  identical; only provider documentation differs.
- [x] Run the existing scoped `gsmlg_config` tests before editing production code:
  `cd apps/gsmlg_config && mix test --no-start --include config_loading`.
  Result: 132 tests, zero failures.

## Task 2: Restore the standalone package (worker ownership)

Files: `packages/gsmlg_toml/**` only.

- [x] Copy the ten embedded parser source files into `packages/gsmlg_toml/lib`.
- [x] Restore the historical tests and fixtures from `887db246^`, retaining the
  parser, lexer, transform, provider and TOML conformance coverage.
- [x] Write a standalone `mix.exs` with `app: :gsmlg_toml`, `version: "1.0.0"`,
  `elixir: "~> 1.14"`, `test/support` in test compilation paths, and a test-only
  Jason dependency. Include source, README and LICENSE in the Hex package;
  preserve upstream Apache-2.0 and published-fork MIT license notices.
- [x] Document `{:gsmlg_toml, "~> 1.0"}` installation, standalone commands and
  the distinction between package source and the umbrella's Hex dependency.
- [x] Run standalone strict compilation, formatting, parser tests and Hex build.
  Result: 317 tests, zero failures; strict compile, formatting and Hex build pass.

## Task 3: Switch the consumer (parent ownership)

Files: `apps/gsmlg_config/lib/{toml,decoder,builder,document,error,lexer,provider,transform}.ex`,
`apps/gsmlg_config/lib/lexer/**`, `apps/gsmlg_config/mix.exs`, `mix.lock`,
`apps/gsmlg_config/test/gsmlg/config/toml_dependency_test.exs`, and migration docs.

- [x] Add a regression asserting the parser and provider belong to the standalone
  `:gsmlg_toml` application and exercise the existing decoding API.
- [x] Run it before the switch; expect failure because that application is absent.
  Result: one test fails because `gsmlg_toml.app` cannot be found.
- [x] Add `{:gsmlg_toml, "~> 1.0"}`, resolve it from Hex and remove the ten embedded
  parser source files. Preserve business modules, schema and defaults.
- [x] Update the configuration README and migration guide to describe the split.
- [x] Run `mix test --no-start --include config_loading` from `apps/gsmlg_config`.
  Result: 133 tests, zero failures. Scoped strict compilation and formatting pass.

## Task 4: Verify the distributable boundary

- [x] Install the newly built archive into a fresh consumer and exercise decode,
  stream, error, transform and provider behavior with no umbrella applications.
  Result: five consumer tests pass with compiler warnings treated as errors.
  A production consumer release boots and reads its TOML through `Toml.Provider`.
- [x] Confirm the umbrella lockfile resolves Hex `gsmlg_toml` 1.0.0 and runtime
  module ownership identifies `:gsmlg_toml`.
- [x] Check scoped formatting and `git diff --check`; review every changed path.
  Spec and code-quality reviews pass. Preserve fixture bytes with package-local
  Git attributes; all ten parser files are recognized as unchanged renames.
- [x] Report exact test results, source location and publication status.

## Validation evidence

- Built archive SHA-256:
  `80c53fe88211a96e36f57608c36dc2464739dee92b02051bb83dd160e5d5b26f`.
- Fresh archive consumer and booted release logs:
  `/tmp/gsmlg-toml-consumer-o6ra91km`.
- Execution platform: Elixir 1.18.5 / OTP 28. Elixir 1.14 was not executed.
- Existing logger unused-function warnings and telemetry `:warn` deprecation
  appeared both before and after the consumer switch; they are outside this change.
- No new Hex version, remote publication, umbrella release or deployment occurred.
