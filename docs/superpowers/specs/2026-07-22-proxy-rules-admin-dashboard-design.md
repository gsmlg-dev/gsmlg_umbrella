# Proxy Rules Admin Dashboard Design

Date: 2026-07-22

## Status

Approved in conversation on 2026-07-22.

This document is an addendum to agent note
`93ffe9ab-78e9-4203-a572-91a69af4f8a7`, "Proxy Rules Integration Plan".
The note remains authoritative for the `GSMLG.ProxyRules` compiler, source,
artifact, persistence, public API, failure, and deployment contracts. This
addendum changes the note's V1 non-goal for a management UI by adding a bounded
operational dashboard in `gsmlg_admin_web`.

## Goal

Give authenticated administrators visibility into the proxy-rules subsystem
without turning V1 into a rule editor. The dashboard exposes runtime state,
diagnostics, published artifact links, and a manual refresh action through the
public `GSMLG.ProxyRules` interface.

## Scope

The V1 admin surface includes:

- Readiness and current artifact generation.
- Remote and local source status.
- Proxy and direct rule counts.
- Compilation statistics and bounded diagnostics.
- Download links for all six public artifacts.
- A manual remote refresh action once refresh support exists.

The V1 admin surface does not include:

- Editing local proxy or direct rule files.
- Editing runtime configuration.
- Uploading GFWList payloads.
- Viewing or logging the complete upstream list.
- Deleting artifacts or last-known-good snapshots.
- A separate admin API.

## Delivery Strategy

Build the dashboard incrementally with the backend milestones.

Milestone 1 adds the authenticated route, navigation entry, LiveView shell, and
explicit not-ready state. The refresh control is visible but disabled with an
explanation until the remote source and coordinator implement refresh. Later
milestones enrich the same page without changing its route or introducing a
second UI.

This approach gives the feature a stable admin home immediately while keeping
the first implementation slice limited to the OTP skeleton and safe empty-state
behavior.

## OTP Boundary

The application lives at `apps/proxy_rules`, uses the OTP application name
`:proxy_rules`, and exposes the namespace `GSMLG.ProxyRules`.

Its Milestone 1 supervision tree is:

```text
GSMLG.ProxyRules.Supervisor
Strategy: one_for_one

|-- GSMLG.ProxyRules.TaskSupervisor
|-- GSMLG.ProxyRules.Store
`-- GSMLG.ProxyRules.Coordinator
```

`Store` is a process because it owns the mutable ETS table. Artifact reads
bypass the GenServer and use a named, protected ETS table with read concurrency
enabled. `Coordinator` serializes refresh orchestration. Stateless source,
parser, compiler, and renderer modules must not become placeholder processes.

The stable public facade is:

```elixir
GSMLG.ProxyRules.get_artifact(list, type)
GSMLG.ProxyRules.metadata()
GSMLG.ProxyRules.refresh()
```

The LiveView must call only this facade. It must not read ETS, access source
files, fetch remote content, compile rules, render artifacts, or persist state.

## Admin Route and Navigation

Add an authenticated LiveView at:

```text
/proxy-rules
```

The route stays inside the existing authenticated admin browser scope and uses
the shared `Layouts.app` shell. Add a `Proxy Rules` navigation group under the
existing `Service` section, preserving the current technical-module taxonomy.

Use the existing admin authorization boundary. V1 introduces no additional
role model beyond the authenticated admin application.

## Page Structure

Use Phoenix DuskMoon components and the existing root theme. The page contains:

1. A header with the page title, readiness badge, and refresh control.
2. Summary statistics for generation, compiled time, proxy rules, and direct
   rules.
3. Source cards for remote GFWList, local proxy list, and local direct list.
4. An artifact table with list, format, size, ETag, last-modified time, and
   download link.
5. A diagnostics section showing aggregate invalid, unsupported, duplicate,
   collapsed, and conflict counts plus a bounded sample of diagnostic entries.

The page must distinguish these states:

- `not_ready`: no artifact has ever been published.
- `ready`: the latest successful artifact is current.
- `stale`: a last-known-good artifact is served after a source or compile
  failure.
- `refreshing`: a newer generation is being fetched or compiled.

Milestone 1 renders `not_ready` without fabricating zero-valued artifact
metadata. Unavailable values use an em dash or explicit "Not available" text.

## Data Flow

```text
Admin LiveView
    |
    v
GSMLG.ProxyRules public facade
    |
    +--> Store ETS read for metadata and artifacts
    |
    `--> Coordinator call for manual refresh
```

The dashboard loads metadata in `mount/3`. Later milestones may subscribe to a
scoped Phoenix PubSub topic published by the proxy-rules integration layer so
the page updates after artifact publication. The LiveView must not poll the
remote source itself.

## Refresh Behavior

Before remote refresh exists, the button is disabled and explains that no
source service is available yet.

After refresh support exists:

- A click calls `GSMLG.ProxyRules.refresh/0` once.
- The Coordinator coalesces duplicate requests.
- The UI enters `refreshing` and prevents repeated clicks.
- Publication updates the dashboard to the new generation.
- Expected failures display a concise flash while the last-known-good artifact
  remains available.

The UI must not claim a refresh succeeded merely because it was accepted.

## Failure Presentation

Operational failures are rendered as state, not page crashes:

- No artifact: show `not_ready` and no download links.
- Source failure with an artifact: show `stale`, retain links, and show the last
  successful generation.
- Refresh rejection: keep the current state and show an error flash.
- Unknown or unavailable metadata: show an explicit unavailable value.

Diagnostics must be bounded. Never render the entire GFWList or an unbounded
collection of invalid rules.

## Configuration Integration

Register the `proxy_rules` section in `GSMLG.Config.Schema` and
`GSMLG.Config.Setup`. Store validated settings in the `:proxy_rules`
application environment without introducing a reverse dependency from
`gsmlg_config`.

Add the section to every environment-specific source TOML because the loader
selects one environment file and does not merge it with the fallback file.

## Testing

Milestone 1 tests cover:

- The `:proxy_rules` application starts its required children.
- The protected ETS store is safe to read before an artifact exists.
- The public facade returns explicit not-ready results.
- Configuration defaults validate and reach the application environment.
- The admin route redirects unauthenticated requests.
- An authenticated request renders the dashboard not-ready state.
- The Service navigation contains Proxy Rules and marks it active.
- The disabled refresh control does not claim to start work.

Later milestone tests add:

- Ready, stale, and refreshing presentations.
- All six artifact links.
- Manual refresh success and failure behavior.
- Live publication updates.
- Bounded diagnostic rendering.

Run only tests scoped to `proxy_rules`, `gsmlg_config`, and the named
`gsmlg_admin_web` route, navigation, and LiveView files while implementing this
feature. Stop rather than fixing unrelated failures.

## Definition of Done

The dashboard work is complete when:

1. Authenticated administrators can open `/proxy-rules` from Service navigation.
2. The page accurately represents not-ready, ready, stale, and refreshing
   states using only the public domain interface.
3. All six published artifacts are linked when available.
4. Manual refresh is safe, coalesced, and reports acceptance separately from
   completion.
5. Backend failures preserve and display the last-known-good artifact.
6. No rule editing or configuration mutation is exposed.
7. Scoped OTP, configuration, navigation, LiveView, and conditional-response
   tests pass.
