# Shared Versions and Hex Release Implementation Plan

> **For agentic workers:** Execute independent version tooling and package
> metadata tasks in parallel. Parent owns Hex orchestration, workflow wiring,
> integration validation and the final commit/merge/push. Never run concurrent
> Mix builds against the same build directory.

**Goal:** Every application shares the root release version, and each product
release publishes all explicitly enabled Hex packages at that version.

**Architecture:** Preserve standalone version literals; dynamically stamp and
check all Mix projects. Package metadata opts into publication, with an explicit
validated internal dependency graph. Prepare a single immutable source tag,
build all archives, publish in dependency order and gate the GitHub release.

**Tech Stack:** Elixir 1.18/OTP 28, Bash, Mix/Hex, GitHub Actions, ExUnit scripts.

## Task 1: Version tooling (worker)

Files: `scripts/update_version.sh`, `scripts/update_version.exs`,
`scripts/lib/release/versions.ex`, `scripts/test/release_versions_test.exs`.

- [x] Add focused regressions for literal and attribute declarations, discovery
  of newly added apps, SemVer validation, no partial edits, foreign working
  directories and read-only version mismatch checks.
- [x] Implement `bash scripts/update_version.sh VERSION` and `--check [VERSION]`
  using Elixir, with no new runtime dependency in Alpine or FreeBSD builds.
- [x] Run `elixir scripts/test/release_versions_test.exs`.

## Task 2: Package metadata (worker)

Files: AWS package metadata/assets; missing CouchDB/IP Geo/telemetry package
assets; socket and telemetry dependency declarations; Tor file list.

- [x] Complete the ten packages' distributable metadata and source assets.
- [x] Give internal package dependencies exact `@version` requirements, using
  `in_umbrella: true` locally and ordinary Hex requirements for distribution
  and external installation. Do not change runtime modules.
- [x] Preserve TOML provenance and unrelated application source.

## Task 3: Hex orchestration (parent)

Files: `scripts/hex_packages.exs`, `scripts/lib/release/hex_packages.ex`,
`scripts/test/hex_packages_test.exs`.

- [x] Add dependency graph, malformed metadata, archive and retry regressions.
- [x] Implement archive build and publish commands with checksums, ordering,
  all-package preflight, exact archive validation and failure propagation.
- [x] Build the real packages; inspect requirements and validate fresh external
  consumers, including telemetry/socket's internal dependency closure.

## Task 4: Workflow and integration (parent)

Files: `.github/workflows/release.yml`, `.github/workflows/ci.yml`, `README.md`,
`docs/deploy.md`, TOML's current development/version documentation.

- [x] Prepare a versioned source tag, pin all build jobs to its SHA, and check
  version parity before compilation. Preserve existing build matrix and secrets.
- [x] Build all Hex packages; publish after other builds; require successful Hex
  publication before creating the GitHub release. Make retries and concurrency
  explicit. Attach package archive evidence to the release.
- [x] Synchronize every current application version to the root version and add
  the standalone regression checks to CI.
- [x] Update release/operator documentation and run scoped script tests,
  formatting, workflow validation, archive checks and `git diff --check`.
- [x] Review scoped changes and confirm readiness for commit, merge and push.

Integration follow-through: commit this implementation, merge to `main`, push
and verify the remote SHA and clean checkout before reporting completion.

## Validation evidence

- Shared version check: root plus all 27 child projects match `1.0.0`.
- Standalone script suites: 10 version tests, 8 release preparation tests,
  11 Hex orchestration tests and 14 metadata tests; all 43 passed.
- Release preparation tests use temporary local bare remotes; ordinary
  prereleases work, and incompatible Docker tags fail before changing sources
  or Git refs. No product release was dispatched.
- All ten real Hex archives built successfully without installed umbrella
  dependencies. A fresh exported source tree with no dependency or build cache
  produced byte-identical archives and manifest checksums.
- Final metadata confirms the shared version, licenses/assets and exact internal
  package requirements. Runtime source modules are unchanged.
- Fresh archive-derived external consumer with a fresh Hex cache resolved
  official registry dependencies, compiled all ten packages, and passed five
  scoped tests without starting application services. Candidate package paths
  override the unpublished versions; registry publication was not exercised.
- All 34 relevant Elixir files pass formatting; Bash syntax, actionlint 1.7.12
  and whitespace checks pass. No unrelated umbrella tests or deployments ran.
- Read-only integration review found no remaining release-flow blockers.
- Hosted release execution and actual Hex publication remain unrun; the Actions
  `HEX_API_KEY` needs publication access to every enabled package, including
  creation rights for new packages.
