# Implementation Plan: [FEATURE]

**Branch**: `[###-feature-name]` | **Date**: [DATE] | **Spec**: [link]
**Input**: Feature specification from `/specs/[###-feature-name]/spec.md`

**Note**: This template is filled in by the `/speckit.plan` command. See `.specify/templates/commands/plan.md` for the execution workflow.

## Summary

[Extract from feature spec: primary requirement + technical approach from research]

## Technical Context

<!--
  ACTION REQUIRED: Replace the content in this section with the technical details
  for the project. The structure here is presented in advisory capacity to guide
  the iteration process.
-->

**Language/Version**: Elixir 1.15+ / OTP 26+
**Framework**: Phoenix 1.7+ with LiveView
**Primary Dependencies**: [e.g., Ecto, Phoenix.PubSub, Guardian, phoenix_duskmoon or NEEDS CLARIFICATION]
**Storage**: MariaDB (Ecto), Mnesia (distributed state), CouchDB (documents) - specify which applies
**Testing**: ExUnit with async test support
**Target Platform**: Linux server (OTP release via Burrito or Docker)
**Umbrella App**: [gsmlg / gsmlg_web / gsmlg_admin_web / gsmlg_commander / new app?]
**UI Technology**: [LiveView / React via Phoenix.React / API-only / CLI]
**Performance Goals**: [domain-specific, e.g., 1000 req/s, <50ms p95, 10k concurrent connections or NEEDS CLARIFICATION]
**Constraints**: [domain-specific, e.g., <200ms p95, <512MB memory per node, distributed deployment or NEEDS CLARIFICATION]
**Scale/Scope**: [domain-specific, e.g., 10k users, distributed cluster, 50 LiveView pages or NEEDS CLARIFICATION]

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Verify compliance with `.specify/memory/constitution.md`:

- [ ] **Umbrella Architecture**: Feature placed in correct app (gsmlg/gsmlg_web/gsmlg_admin_web/gsmlg_commander)
- [ ] **Phoenix DuskMoon UI**: Uses phoenix_duskmoon components + TailwindCSS (no custom CSS frameworks)
- [ ] **Modern Frontend Workflow**: Bun for JS, TailwindCSS for styling, Phoenix asset pipeline
- [ ] **OTP Distribution Model**: Appropriate for standalone vs commander deployment model
- [ ] **Test-First Development**: Test tasks included and written BEFORE implementation tasks

**Complexity Justification**: If any principle is violated, document in Complexity Tracking section below.

## Project Structure

### Documentation (this feature)

```text
specs/[###-feature]/
├── plan.md              # This file (/speckit.plan command output)
├── research.md          # Phase 0 output (/speckit.plan command)
├── data-model.md        # Phase 1 output (/speckit.plan command)
├── quickstart.md        # Phase 1 output (/speckit.plan command)
├── contracts/           # Phase 1 output (/speckit.plan command)
└── tasks.md             # Phase 2 output (/speckit.tasks command - NOT created by /speckit.plan)
```

### Source Code (Elixir Umbrella Structure)
<!--
  ACTION REQUIRED: Specify which umbrella app(s) this feature affects.
  Use the actual apps/ directory structure and follow Phoenix/Elixir conventions.
-->

```text
# Umbrella app structure (select applicable apps for this feature)
apps/
├── gsmlg/                    # Core business logic & Ecto schemas
│   ├── lib/gsmlg/
│   │   ├── [domain]/         # Domain-specific modules
│   │   ├── schemas/          # Ecto schemas
│   │   └── [new_feature]/    # Feature-specific logic
│   ├── priv/repo/migrations/ # Database migrations
│   └── test/gsmlg/
│
├── gsmlg_web/                # Public Phoenix web app (port 4110)
│   ├── lib/gsmlg_web/
│   │   ├── controllers/      # Phoenix controllers
│   │   ├── live/             # LiveView modules
│   │   └── components/       # Phoenix components
│   ├── assets/               # Frontend assets (Bun + TailwindCSS)
│   └── test/gsmlg_web/
│
├── gsmlg_admin_web/          # Admin Phoenix web app (port 4111)
│   ├── lib/gsmlg_admin_web/
│   │   ├── controllers/
│   │   ├── live/
│   │   └── components/
│   ├── assets/               # Admin-specific assets
│   └── test/gsmlg_admin_web/
│
├── gsmlg_commander/          # Distributed command client
│   ├── lib/gsmlg_commander/
│   └── test/gsmlg_commander/
│
└── gsmlg_[new_app]/          # New umbrella app (if creating one)
    ├── lib/
    └── test/
```

**Structure Decision**: [Document which app(s) this feature modifies and why.
Reference specific directories like apps/gsmlg_web/lib/gsmlg_web/live/ for new LiveViews]

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| [e.g., 4th project] | [current need] | [why 3 projects insufficient] |
| [e.g., Repository pattern] | [specific problem] | [why direct DB access insufficient] |
