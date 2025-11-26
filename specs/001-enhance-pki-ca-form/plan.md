# Implementation Plan: Enhanced PKI CA Creation Form

**Branch**: `001-enhance-pki-ca-form` | **Date**: 2025-11-18 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/001-enhance-pki-ca-form/spec.md`

**Note**: This template is filled in by the `/speckit.plan` command. See `.specify/templates/commands/plan.md` for the execution workflow.

## Summary

Enhance the PKI CA creation page (`/pki/ca/new`) to use phoenix_duskmoon form components with individual inputs for all X.509 subject fields, support for multiple key types (RSA, ECDSA, Ed25519) with appropriate key sizes, datetime range selector for validity periods, and optional private key encryption. The form will provide comprehensive field-level validation, real-time feedback, and a consistent UI experience aligned with the phoenix_duskmoon design system.

## Technical Context

**Language/Version**: Elixir 1.15+ / OTP 26+
**Framework**: Phoenix 1.7+ with LiveView
**Primary Dependencies**: Ecto, Phoenix.LiveView, phoenix_duskmoon, X509 (Elixir library), GSMLG.PKI (existing PKI module)
**Storage**: MariaDB (Ecto) for CA metadata and certificates
**Testing**: ExUnit with async test support, Phoenix.ConnTest for LiveView testing
**Target Platform**: Linux server (OTP release via Burrito or Docker)
**Umbrella App**: gsmlg_admin_web (admin interface modification), gsmlg (PKI business logic)
**UI Technology**: Phoenix LiveView with phoenix_duskmoon components
**Performance Goals**: Form renders in <300ms, validation feedback within 300ms of field blur, CA creation completes within 3 seconds for standard configurations
**Constraints**: Must maintain backward compatibility with existing GSMLG.PKI.CA API, form state must persist on validation errors, datetime handling must support timezone conversion
**Scale/Scope**: Single LiveView page enhancement with approximately 15-20 form fields, 4 user stories (P1-P3), supports 3 key types with dynamic key size options

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Verify compliance with `.specify/memory/constitution.md`:

- [x] **Umbrella Architecture**: Feature modifies gsmlg_admin_web (admin UI for PKI CA creation page) and gsmlg (PKI business logic for key generation and encryption). No cross-app circular dependencies introduced.
- [x] **Phoenix DuskMoon UI**: All form components use phoenix_duskmoon (dm_input, dm_select, dm_checkbox, dm_form, etc.) with TailwindCSS utility classes for layout. No custom CSS frameworks.
- [x] **Modern Frontend Workflow**: Uses existing Bun setup in gsmlg_admin_web/assets, TailwindCSS for styling, Phoenix asset pipeline via `mix assets.deploy`. No new JS dependencies required for basic form (LiveView handles interactivity).
- [x] **OTP Distribution Model**: Feature is admin-only (gsmlg_admin_web), accessible in standalone release. Commander client not affected but can theoretically access admin interface if connected.
- [x] **Test-First Development**: Test tasks will be created BEFORE implementation tasks in tasks.md phase. Tests cover LiveView form rendering, validation logic, CA creation flow, and key type selection behavior.

**Complexity Justification**: No constitutional violations. Feature aligns with all core principles.

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

**Structure Decision**:

This feature modifies two umbrella apps:

1. **apps/gsmlg_admin_web**: Primary changes to the PKI CA creation LiveView
   - `lib/gsmlg/admin_web/live/pki_live/ca_live/new.ex` - Enhanced LiveView module with new form handling
   - `lib/gsmlg/admin_web/live/pki_live/ca_live/new.html.heex` - Complete form redesign with phoenix_duskmoon components
   - `lib/gsmlg/admin_web/live/pki_live/components/` - New shared components (datetime range picker, key size selector)
   - `test/gsmlg/admin_web/live/pki_live/ca_live/new_test.exs` - LiveView tests

2. **apps/gsmlg**: Enhanced PKI business logic
   - `lib/gsmlg/pki/ca.ex` - Extended API to support new key types and encryption options
   - `lib/gsmlg/pki/key_generator.ex` - New module for generating different key types (RSA/ECDSA/Ed25519)
   - `lib/gsmlg/pki/schemas/certificate_authority.ex` - Schema updates for new fields (key_type, encryption_enabled)
   - `priv/repo/migrations/` - Database migrations for new CA fields
   - `test/gsmlg/pki/` - Unit tests for key generation and encryption logic

**Rationale**: gsmlg_admin_web contains the admin UI per umbrella architecture principle. Core PKI logic belongs in gsmlg for reusability across both web apps and commander client.

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

No constitutional violations. Feature fully compliant with all core principles.

## Phase Completion Status

### Phase 0: Research & Decisions ✅

**Completed**: 2025-11-18

**Deliverables**:
- [research.md](research.md) - Comprehensive technical research covering:
  - Current implementation analysis
  - Technology stack evaluation (phoenix_duskmoon v7.0, X509 library, LiveView)
  - Key decisions: Individual subject fields, dynamic key size selection, HTML5 datetime picker
  - Form validation strategy with Ecto changesets
  - Private key encryption using PKCS#8
  - Testing approach and performance considerations

**Key Findings**:
- phoenix_duskmoon provides all necessary form components except datetime range picker (custom implementation needed)
- X509 Elixir library supports RSA and ECDSA; Ed25519 requires Erlang crypto module (OTP 24+)
- LiveView `phx-change` events enable dynamic key size options without JavaScript
- PKCS#8 encryption via `:public_key` module provides industry-standard key protection

### Phase 1: Design & Contracts ✅

**Completed**: 2025-11-18

**Deliverables**:
- [data-model.md](data-model.md) - Complete data structures:
  - Extended `CertificateAuthority` schema with 3 new fields
  - `CAFormData` embedded schema for form validation (15 fields)
  - `KeyAlgorithmDetails` JSON structure for algorithm metadata
  - Database migration for backward-compatible schema changes
  - Comprehensive validation rules and state transitions

- [contracts/pki_context.md](contracts/pki_context.md) - API contracts:
  - `PKIContext.initialize_ca/2` extended signature with new opts
  - `PKIContext.get_key_size_options/1` helper function
  - LiveView integration patterns and event handlers
  - Security considerations for password handling
  - Complete testing contract with example tests

- [quickstart.md](quickstart.md) - Developer implementation guide:
  - 9-phase implementation checklist (~9 hours total)
  - Key files to create/modify
  - Component structure and event flow
  - Code snippets for LiveView handlers and form submission
  - Testing commands and troubleshooting guide

**Diagrams**:
- Form event flow: User action → LiveView event → Backend action
- Data transformation: Form fields → Subject DN → CA entity
- State transitions: Created → Active → Revoked/Expired

### Phase 2: Task Breakdown

**Status**: Not yet generated (requires `/speckit.tasks` command)

**Next Step**: Run `/speckit.tasks` to generate dependency-ordered task list in `tasks.md`

## References

- **Specification**: [spec.md](spec.md) - Feature requirements and user stories
- **Research**: [research.md](research.md) - Technical decisions and alternatives
- **Data Model**: [data-model.md](data-model.md) - Entity structures and validation
- **API Contract**: [contracts/pki_context.md](contracts/pki_context.md) - Function signatures and integration
- **Quickstart**: [quickstart.md](quickstart.md) - Developer implementation guide

## Estimated Implementation Time

Based on quickstart checklist breakdown:
- **Phase 1-2** (Schema & Validation): 1.25 hours
- **Phase 3-4** (Key Generation & Components): 1.75 hours
- **Phase 5-6** (LiveView & Template): 3.5 hours
- **Phase 7** (PKI Context): 1 hour
- **Phase 8-9** (Testing & QA): 3 hours

**Total**: ~11 hours for implementation + testing

**Recommended Sprint**: 2-3 days with testing and code review
