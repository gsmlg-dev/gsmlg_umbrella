# Hologram toolbox migration

The user confirmed migration of all seven existing toolbox tools and adoption of
Hologram 0.12.2 with Elixir 1.19 across development, CI and release builds.

## Framework choice

Use Hologram 0.12.2 only in `gsmlg_web`. Official umbrella support starts at
0.11.0, which also raises the requirements to Elixir 1.19 and OTP 28.1.
The existing local OTP 28.5.0.5 meets that requirement. Pin build images to an
Elixir 1.19 release on OTP 28 and align CI/devenv declarations.

The alternatives are retaining 0.10.1 on Elixir 1.18 without official umbrella
support, or splitting tools into another service. Both add constraints that the
approved current-version integration avoids. Hologram discovers the application
that directly depends on it; keeping that dependency exclusively in `gsmlg_web`
allows the existing admin endpoint to coexist.

## Application boundary

Create eight Hologram pages under `apps/gsmlg_web/lib/gsmlg/web/hologram/pages`:

| Existing URL | Responsibility |
| --- | --- |
| `/toolbox` | Seven-tool catalogue and navigation |
| `/toolbox/ip_geo` | IP lookup, location fields and a D3 map |
| `/toolbox/whois` | WHOIS/RDAP selection and registration results |
| `/toolbox/mac_manufacturer` | MAC vendor lookup |
| `/toolbox/svg2react` | SVG input and generated React source |
| `/toolbox/svg_autocrop` | Browser SVG bounds measurement and output |
| `/toolbox/ip_to_geomap` | Multiple IP lookups and progressive map points |
| `/toolbox/screensaver` | Existing smoke animation and fullscreen video |

Hologram owns form state, input, loading, errors and escaped result rendering.
Public lookup commands call the existing `GSMLG.IpGeo`, `GSMLG.Whois`,
`GSMLG.MAC` and `GSMLG.SVG2React` modules. Existing public JSON endpoints and
the CSRF-protected SVG conversion POST retain their contracts. No new data
model, migration or background service is needed.

## Shell, routing and locale

Use a Hologram full-document shell with `Hologram.UI.Runtime`, existing DuskMoon
CSS, native markup and necessary DuskMoon web components. Preserve the header,
tool links, footer language navigation and persisted sunshine/moonlight theme.
Phoenix HEEx function components and LiveView hooks do not run inside HOLO
templates, so the shell must use Hologram actions/browser adapters for behavior.

Place a transport-only Hologram wrapper after `Plug.Session` and before the
Phoenix router. Keep the eight toolbox GET declarations in the Phoenix browser
and optional-auth pipelines, then call the official `Hologram.Router` plug from
`ToolboxController.hologram/2` to render the complete document. This preserves
existing session, CSRF, secure-header and locale processing. Keep the original
SVG conversion POST on its Phoenix action. Toolbox pages remain public.
Hologram supplies CSRF/session verification for its own command transport;
every tool command independently validates its public input.

Resolve locale through the existing `?lang`, session, Accept-Language and default
precedence. Prepare translated strings on the server and serialize only the
locale and display messages into page state. Client actions do not call
Gettext or rely on an HTTP process dictionary. The shell restores the persisted
theme into its own state after mounting so hydration and later actions retain it. Language changes use document
navigation so session and translated state are refreshed consistently.

## Browser integrations

Keep three focused browser integrations in one adapter module, invoked through Hologram
`js_import`/`JS.call` interfaces:

- D3 map mounting and point updates, shared by the two IP tools.
- SVG XML parsing, sandboxed browser measurement and serialization; pasted SVG
  remains text elsewhere and cannot execute scripts during measurement.
- Three.js smoke animation, captureStream and fullscreen; remove observers,
  animation frames, media tracks and WebGL resources when its canvas leaves the
  document or on pagehide. Retain only target IDs and one native lifecycle
  watcher to remount on history reinsertion or persisted pageshow; explicit
  unmount also removes that watcher. Share the registry across Hologram's
  separately bundled page adapters so restored fullscreen actions reach the
  current renderer. A ready-state canvas marker lets a new document discover
  restored screensaver markup even when Hologram skips the completed setup
  action. Hologram has no documented component destroy callback, so cleanup
  and restoration use native browser lifecycle APIs.

Retain the existing tools' capabilities and library choices. Do not add SVG
optimization, new animation modes, new RDAP features or unrelated UI redesign.

## Build integration

Append the Hologram compiler only to the endpoint app. Provide Node/npm for its
build process alongside existing Bun/Tailwind; keep generated Hologram assets
in `gsmlg_web/priv/static/hologram`, serve them from the endpoint, ignore them
in Git and include them in releases. Add Hologram source paths to Tailwind.
Keep development startup and test compilation explicit through Hologram's
supported startup mechanism. Align the relevant workflow caches with the new
Elixir version so old compiler artifacts are not restored as current builds.
Development uses locked Elixir 1.19.6; CI and regular/Alpine builders use 1.19.5
because its images support both amd64 and arm64. Let Burrito resolve the ERTS
matching the build host instead of retaining the old OTP 27 override. Provide
the environment explicitly at release startup and reuse the existing public
endpoint signing key when SECRET_KEY_BASE is not supplied.

## Acceptance

1. All eight original GET addresses render Hologram documents with the correct
   page, existing DuskMoon styling and working tool navigation.
2. Scoped tests cover public page routing, locale resolution, form state,
   deterministic lookup success/failure and unchanged toolbox API contracts.
3. Browser qualification exercises WHOIS/RDAP results, MAC and IP lookup,
   SVG-to-React, SVG bounds cropping, progressive maps and screensaver lifecycle.
   External lookup behavior uses deterministic fixtures where needed; no
   third-party availability is presented as local implementation evidence.
4. Re-entering and leaving browser-heavy tools does not accumulate animation
   frames, media tracks or WebGL resources. Screensaver animation and fullscreen
   work after browser Back and persisted page restoration. Theme and language
   work across pages.
5. Strict compilation, changed-file formatting/lint and production web asset
   compilation pass under Elixir 1.19/OTP 28.1 or newer. Generated runtime/page
   bundles exist in the web application's static directory.
6. Preserve unrelated files and report any out-of-scope test failures without
   attempting to repair them. This work does not publish or deploy a release.

## Verified upstream references

- <https://hex.pm/api/packages/hologram/releases/0.12.2>
- <https://github.com/bartblast/hologram/releases/tag/v0.11.0>
- <https://github.com/bartblast/hologram/blob/v0.12.2/llms-full.txt>
- <https://github.com/bartblast/hologram/blob/v0.12.2/lib/hologram/reflection.ex>
- <https://github.com/bartblast/hologram/blob/v0.12.2/lib/hologram/controller.ex>
