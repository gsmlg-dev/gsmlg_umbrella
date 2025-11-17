<!--
SYNC IMPACT REPORT
==================
Version Change: 1.0.1 → 1.0.2 (Patch - clarification)
Modified Principles:
  - I. Umbrella Architecture - Clarified gsmlg_component as shared UI component library
  - II. Phoenix DuskMoon UI Standard - Added reference to gsmlg_component for shared components
Modified Sections: None (only principle clarifications)
Added Sections: None
Removed Sections: None
Templates Requiring Updates:
  ✅ plan-template.md - No changes needed (already aligned)
  ✅ spec-template.md - No changes needed (already aligned)
  ✅ tasks-template.md - No changes needed (already aligned)
Follow-up TODOs: None
Rationale: PATCH bump - This clarifies the role of gsmlg_component as a shared UI
component library between gsmlg_web and gsmlg_admin_web. The principle was already
listed in Umbrella Architecture, but its specific purpose (UI component sharing) was
not explicit. No semantic changes to requirements or governance, only improved clarity.
-->

# GSMLG Umbrella Constitution

## Core Principles

### I. Umbrella Architecture
Every major feature must respect the umbrella application boundaries:
- **gsmlg**: Core business logic, Ecto schemas, and shared services
- **gsmlg_web**: Public-facing Phoenix application (port 4110)
- **gsmlg_admin_web**: Administrative Phoenix application (port 4111)
- **gsmlg_commander**: Distributed command execution client
- **gsmlg_component**: Shared UI components library for gsmlg_web and gsmlg_admin_web
- **gsmlg_telemetry**: Event collection, metrics aggregation, and observability
- **gsmlg_logger**: Log formatting and output backends
- **Other shared libraries**: Utility apps (gsmlg_config, gsmlg_aws, etc.)

New features MUST be placed in the appropriate application. Cross-app dependencies MUST be explicitly declared in `mix.exs`. Circular dependencies between apps are PROHIBITED.

Component reuse requirements:
- UI components shared between web apps MUST be placed in `gsmlg_component`
- Components specific to one web app SHOULD remain in that app's component directory
- Business logic MUST NOT be placed in gsmlg_component (use gsmlg core app instead)

**Rationale**: Maintains clear separation of concerns, enables independent deployment, supports distributed OTP architecture, and promotes UI consistency through shared components.

### II. Phoenix DuskMoon UI Standard
All user interfaces MUST use the phoenix_duskmoon package for UI components:
- Components MUST extend DaisyUI patterns via phoenix_duskmoon
- Custom styling MUST be applied through TailwindCSS utility classes
- React components MUST be integrated via Phoenix.React when LiveView is insufficient
- Component consistency across both web applications (public and admin) is REQUIRED
- Shared components between gsmlg_web and gsmlg_admin_web MUST be placed in `gsmlg_component`

**Rationale**: Ensures consistent user experience, leverages battle-tested DaisyUI patterns, maintains design system coherence across multiple Phoenix applications, and promotes code reuse through the shared component library.

### III. Modern Frontend Workflow
Frontend assets MUST follow the established build pipeline:
- **JavaScript**: Bun as the package manager and bundler (not npm/yarn)
- **CSS**: TailwindCSS for styling with app-specific configuration
- **Asset compilation**: Phoenix asset pipeline with `mix assets.deploy`
- **Development mode**: Live reload via `mix phx.server` with Bun watching

Node modules and compiled assets MUST NOT be committed. The `assets/` directory structure MUST be preserved per Phoenix conventions.

**Rationale**: Bun provides faster builds and better developer experience. TailwindCSS enables rapid UI development while maintaining consistency.

### IV. OTP Distribution Model
The project follows a dual OTP release strategy:
- **Standalone Release** (`gsmlg_umbrella_standalone`): Monolithic deployment including both web apps
- **Commander Release** (`gsmlg_commander`): Lightweight distributed client connecting to admin_web

Features requiring distributed coordination MUST use Erlang distribution or Phoenix PubSub. Commander-specific functionality MUST be implemented in `apps/gsmlg_commander/`. Administrative APIs MUST support both web UI and commander client access.

**Rationale**: Supports both monolithic deployment for simplicity and distributed deployment for scalability. Enables remote administration via commander client.

### V. Test-First Development (NON-NEGOTIABLE)
All new features and bug fixes MUST follow test-driven development:
- **Write tests FIRST**: Create ExUnit test cases before implementation
- **Tests MUST fail initially**: Verify red state before writing code
- **Tests define the contract**: API, behavior, and edge cases documented via tests
- **Coverage requirements**: Core business logic MUST have unit tests, critical paths MUST have integration tests

Test organization:
- Unit tests in `test/<app_name>/` mirroring `lib/<app_name>/` structure
- Integration tests for multi-service features
- Controller/LiveView tests for HTTP endpoints
- Channel tests for WebSocket functionality

**Rationale**: TDD ensures code correctness, prevents regressions, and serves as living documentation. ExUnit provides excellent tooling for Elixir testing.

## Technical Standards

### Database Strategy
- **Primary database**: MariaDB via Ecto for relational data
- **Distributed state**: Mnesia for node coordination and ephemeral data
- **Document storage**: CouchDB for unstructured data when appropriate
- **Migrations**: All schema changes via Ecto migrations, never manual SQL in production

### Configuration Management
- **Custom config system**: `apps/gsmlg_config` with TOML-based configuration
- **Config files**: `priv/gsmlg.toml` (base), environment-specific overlays
- **Secrets**: MUST NOT be committed; use environment variables or secure vaults
- **Runtime config**: Use `config/runtime.exs` for environment-specific settings

### Logging and Observability
The project uses a dual-app architecture for observability:
- **gsmlg_telemetry**: Event collection, metrics aggregation, and span tracking
- **gsmlg_logger**: Log formatting and output (attached as backend to telemetry when needed)

Requirements:
- **Event collection**: Use `GSMLG.Telemetry` for emitting custom events and structured logging
- **Metadata richness**: Include user_id, request_id, module context in all telemetry events
- **Performance monitoring**: Use `GSMLG.Telemetry.span/3` for measuring critical operations
- **Logger integration**: Attach gsmlg_logger to telemetry handlers for formatted output
- **Backend flexibility**: Configure console, file, or CloudWatch backends via gsmlg_telemetry config
- **Phoenix/Ecto integration**: Automatic telemetry handlers for web requests and database queries

**Rationale**: Separating event collection (telemetry) from formatting (logger) provides flexibility in output destinations and formats while maintaining a unified telemetry pipeline.

### Authentication and Authorization
- **JWT tokens**: Guardian-based authentication across all applications
- **OAuth integration**: GitHub OAuth for user authentication
- **Session management**: Phoenix.SessionProcess for distributed sessions
- **Role-based access**: Implement via Guardian claims and function plugs

## Development Workflow

### Feature Development Process
1. **Specification**: Create feature spec in `/specs/[###-feature-name]/spec.md`
2. **Planning**: Run `/speckit.plan` to generate implementation plan
3. **Test Creation**: Write failing tests per TDD principle
4. **Implementation**: Develop feature following the task list
5. **Validation**: Ensure all tests pass, run `mix test --cover`
6. **Code Review**: PR review focusing on architecture alignment and test coverage

### Quality Gates
Before merging any feature:
- [ ] All ExUnit tests passing (`mix test`)
- [ ] No compiler warnings (`mix compile --warnings-as-errors`)
- [ ] Credo linting passing (`mix credo --strict`)
- [ ] Test coverage meets minimum threshold
- [ ] Constitution compliance verified (correct app placement, UI standards, etc.)
- [ ] Documentation updated (README, module docs, type specs)

### Database Migration Standards
- Migrations MUST be reversible (`up` and `down` functions)
- Breaking schema changes MUST follow multi-step deployment (add new, migrate data, remove old)
- Production migrations MUST be tested in staging environment
- Data migrations MUST be idempotent

### Deployment Process
- **Development**: `mix phx.server` for local development
- **Staging**: Docker image built from `Dockerfile` with environment config
- **Production**: Burrito standalone binary (`MIX_ENV=prod BURRITO_TARGET=linux_amd64 mix release`)
- **Database**: Ecto migrations run before application start
- **Rollback**: Keep previous release available for quick rollback

## Governance

### Amendment Process
This constitution may be amended when:
- New architectural patterns emerge requiring codification
- Technology stack changes significantly (e.g., new UI framework)
- Team consensus on improved practices

Amendment requirements:
1. Proposal documented with rationale
2. Impact analysis on existing templates and workflows
3. Team review and approval
4. Version increment per semantic versioning
5. Migration plan for existing code (if applicable)

### Version Management
Constitution follows semantic versioning:
- **MAJOR**: Breaking changes to core principles (e.g., removing umbrella architecture)
- **MINOR**: New principles added or significant expansions
- **PATCH**: Clarifications, typo fixes, non-semantic improvements

### Compliance and Enforcement
- All pull requests MUST be reviewed against this constitution
- CI/CD pipeline SHOULD include automated checks where feasible
- Complexity violations MUST be justified in `plan.md` Complexity Tracking section
- Team retrospectives SHOULD review constitutional adherence quarterly

### Living Document Philosophy
This constitution is a living document. It should:
- Capture team consensus on non-negotiable practices
- Evolve based on lessons learned and project growth
- Remain concise and actionable (not bureaucratic)
- Be referenced in daily development decisions

**Version**: 1.0.2 | **Ratified**: 2025-01-17 | **Last Amended**: 2025-01-18
