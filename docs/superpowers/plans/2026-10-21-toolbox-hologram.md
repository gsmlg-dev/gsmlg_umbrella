# Hologram Toolbox Implementation Plan

> For agentic workers: execute independent page, browser adapter and integration
> tasks in parallel, preserving explicit file ownership. Track verification below.

**Goal:** Migrate the entire public toolbox to Hologram 0.12.2 on Elixir 1.19.

**Architecture:** Eight Hologram pages reuse existing public domain services and
API contracts. A shared DuskMoon shell and server-prepared translations support
all pages; narrow JS adapters handle D3 maps, SVG bounds and Three.js resources.

**Tech Stack:** Elixir 1.19, OTP 28.1+, Phoenix 1.8, Hologram 0.12.2, DuskMoon,
Tailwind 4, Bun and Node/npm.

## Task 1: Framework and toolchain integration (parent)

- [x] Record the baseline test setup limitation and qualify the isolated build.
- [x] Add the web-app dependency/compiler; fetch only required dependencies.
- [x] Upgrade devenv/CI/container Elixir declarations and provide Node/npm.
- [x] Implement the Hologram shell, translated messages and browser wrapper.
- [x] Prepare toolbox requests before Hologram routing while preserving Phoenix
      API/CSRF paths. Remove migrated HTML handlers/templates and obsolete entrypoints.
- [x] Verify page routing and unchanged JSON/POST responses with scoped tests.

Primary files: `apps/gsmlg_web/mix.exs`, `mix.lock`, `config/config.exs`,
`apps/gsmlg_web/lib/gsmlg/web/{endpoint,router}.ex`,
`apps/gsmlg_web/lib/gsmlg/web/hologram/{shell,messages,browser,router}.ex`,
`apps/gsmlg_web/assets/css/app.css`, `devenv.nix`, relevant workflow and Docker files.

## Task 2: Lookup and catalogue pages (lookup worker)

- [x] Add action/command regressions for empty input, loading, success and error.
- [x] Implement `Index`, `IpGeo`, `Whois`, `MacManufacturer` and `Svg2React`
      pages in `apps/gsmlg_web/lib/gsmlg/web/hologram/pages`.
- [x] Preserve WHOIS/RDAP field rendering and SVG converter options; render
      external values as escaped text and restrict external links to HTTP(S).
- [x] Run scoped lookup page tests after the parent completes dependency setup.

Test file: `apps/gsmlg_web/test/gsmlg_web/hologram/lookup_pages_test.exs`.

## Task 3: Browser adapters (browser worker)

- [x] Add behavior-focused Bun tests for SVG measurement safety and resource cleanup.
- [x] Implement `mountMap`, `updateMap`, `autocropSvg`, `mountScreensaver`,
      `startFullscreen`, `unmountScreensaver` in
      `apps/gsmlg_web/assets/js/hologram/browser.mjs` and focused modules as needed.
- [x] Observe native document removal and pagehide to release animation/media/
      WebGL resources. Return serializable success/error values to Hologram.
- [x] Restore resources on history reinsertion, persisted pageshow and fresh
      document snapshots, sharing records across separate page bundles and
      retaining explicit cleanup.
- [x] Run `bun test apps/gsmlg_web/test/js/hologram_browser_test.mjs`.

## Task 4: Browser-dependent pages (parent)

- [x] Implement `SvgAutocrop`, `IpToGeomap`, `Screensaver` pages using the browser
      adapter contract and explicit form/loading/result/error state.
- [x] Verify real browser action dispatch, map updates, cropping, fullscreen
      handling, cleanup and repeated navigation with the local isolated server.

## Task 5: Qualification and final review (parent)

- [x] Run only toolbox/Hologram and directly affected locale/API scoped tests.
- [x] Run strict compilation and formatting/lint for changed Elixir files.
- [x] Compile production web assets and verify runtime/page bundle output.
- [x] Review the final diff against every requirement in the design document.
- [x] Record exact results and limits; leave publication/deployment untouched.

## Verification record

- Worktree: `.trees/toolbox-hologram`, branch `codex/toolbox-hologram`, baseline
  `417a0340117cf0e4d324bc86a9cf9b66c4982810`. Local toolchain: Elixir 1.19.6,
  OTP 28.5.0.5. No existing service was restarted.
  The untracked `deps` symlink is local build setup, not a source change to stage.
- Original-checkout baseline stopped before ExUnit because stale generated
  app/dependency metadata prevented startup. The isolated build was regenerated.
- Created and migrated only task-owned database `gsmlg_hologram_test_20261021`;
  the initial shared test database lacked Styx tables and was left unchanged.
- PASS: toolbox controller, new Hologram pages and locale plug: **34 tests,
  zero failures**. Includes all eight GETs, browser headers, locale precedence,
  real MAC lookup, deterministic IP service/API fixture, legacy SVG conversion
  JSON and CSRF rejection on both transports.
- PASS: browser adapters: **16 Bun tests, 83 assertions**; SVG script-disabled
  measurement, malformed XML, coordinate zero, WebGL/media cleanup, history and
  persisted-page remount, fresh-document snapshot discovery, concurrent setup
  and separate page-bundle bindings.
- PASS: scoped Workflow lifecycle compatibility regression: **9 tests**, following
  a minimal explicit Decision struct binding required by the Elixir 1.19 checker.
- PASS: `MIX_ENV=test HOLOGRAM_START=1 mix compile --warnings-as-errors`;
  changed-file formatting and Credo with no reported issues.
- PASS: real Chrome interactions for MAC, IP+map, WHOIS and RDAP (task-only
  cache fixtures), SVG-to-React, SVG crop (`viewBox="10 20 30 40"`), progressive
  map lookup, smoke rendering, user-gesture video fullscreen, media-track
  shutdown and SPA navigation away from the canvas. Theme survives hydration,
  result actions and document navigation; Chinese and 390px layout verified.
  External WHOIS/RDAP/GeoIP availability is not inferred from fixture success.
- PASS: final Chrome screensaver regressions for SPA Back and fresh-document
  Back both resume rendering with one active renderer and working user-gesture
  fullscreen. Leaving disposes four WebGL resources and ends media tracks.
  Synthetic persisted PageTransitionEvents also stop/remount correctly; this
  browser recreated the document on actual Back, so actual bfcache restoration
  is covered by adapter regressions rather than claimed as a browser result.
- PASS: Tailwind web CSS and minified public Bun entrypoints; no obsolete tool
  entrypoints remain.
- PASS: production `mix release gsmlg_umbrella --overwrite` assembled the local
  release and tar archive. Archive inspection confirms eight logical page
  bundles, the runtime JS and exactly the three required runtime PLT files.
- PASS: selective startup from the assembled release (`gsmlg` core plus public
  web endpoint) with `MIX_ENV`, `HOLOGRAM_ENV` and `SECRET_KEY_BASE` absent on
  entry. Verified production environment, TOML signing bridge, actual task
  database, eight documents and emitted bundles returning HTTP 200, command
  response 200, missing-CSRF rejection 403 and transport ping 200. Temporary
  telemetry logs and Bun port were isolated; task ports were closed afterward.
  Smoke logs: `/tmp/gsmlg-hologram-release-{build,smoke}.log`.
- PASS: four workflow YAML structures, all 12 setup-beam declarations, locked
  Nix module evaluation, regular/Alpine image architecture manifests, and
  actual Burrito OTP 28.5.0.5 archive layout/version.
- PASS: independent full migration review and lifecycle repair follow-up found
  no remaining actionable P1/P2 issues; browser acceptance is recorded separately.
- NOT RUN: full umbrella boot, full Docker image builds, hosted CI, deployment
  and public release. GeoIP datasets are absent in the local release environment;
  external lookup availability is not qualified by the selective release smoke.
