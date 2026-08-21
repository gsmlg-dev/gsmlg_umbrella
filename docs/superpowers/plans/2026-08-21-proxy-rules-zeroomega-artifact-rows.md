# Proxy Rules ZeroOmega Artifact Rows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add parameterized Switchy and PAC download rows, each combining Proxy and Direct rules, to the admin Artifacts table.

**Architecture:** Extend the existing LiveView row model with a `parameterized` flag and append two link-only rows from the same metadata load. Do not render ZeroOmega outputs or perform additional Store reads; parameterized cells truthfully display `Parameterized` instead of fixed Size/ETag values.

**Tech Stack:** Elixir 1.18, Phoenix LiveView 1.2, phoenix_duskmoon table components, ExUnit LiveView tests.

---

### Task 1: Add Parameterized Artifact Rows

**Files:**
- Modify: `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/proxy_rules_live/index.ex`

- [ ] **Step 1: Write the failing ready-state LiveView assertions**

Extend `renders summary, sources, bounded diagnostics, and six absolute artifacts`
to assert these exact public links and labels:

```elixir
switchy_url =
  "#{base_url}/rules/zeroomega/switchy?mode=result&match_profile=squid&default_profile=direct"

pac_url = "#{base_url}/rules/zeroomega/pac?proxy=10.100.0.1:3128"

assert has_element?(
  view,
  "#proxy-rules-artifacts a[href='#{switchy_url}']" <>
    "[aria-label='Download Proxy + Direct Switchy result']"
)

assert has_element?(
  view,
  "#proxy-rules-artifacts a[href='#{pac_url}']" <>
    "[aria-label='Download Proxy + Direct PAC']"
)

assert render(view) =~ "Parameterized"
```

Add an empty-state assertion that neither `/rules/zeroomega/switchy` nor
`/rules/zeroomega/pac` appears before a generation is published.

- [ ] **Step 2: Run the focused tests and verify RED**

```bash
devenv shell -- mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs
```

Expected: the two new anchor assertions fail because only six fixed rows exist.

- [ ] **Step 3: Extend the row model without extra exporter calls**

Change state construction to pass `compiled_at`:

```elixir
artifacts:
  artifact_rows(
    Map.get(metadata, :rendered_outputs, %{}),
    Map.get(metadata, :compiled_at)
  )
```

Build existing rows with `parameterized: false`. When fixed rows are non-empty,
append these maps with `parameterized: true`:

```elixir
%{
  list_label: "Proxy + Direct",
  format_label: "Switchy result",
  content_length: nil,
  etag: nil,
  last_modified: compiled_at,
  parameterized: true,
  url:
    "#{base_url}/rules/zeroomega/switchy?mode=result&match_profile=squid&default_profile=direct"
}

%{
  list_label: "Proxy + Direct",
  format_label: "PAC",
  content_length: nil,
  etag: nil,
  last_modified: compiled_at,
  parameterized: true,
  url: "#{base_url}/rules/zeroomega/pac?proxy=10.100.0.1:3128"
}
```

In Size and ETag columns, render `Parameterized` when the flag is true;
otherwise preserve the existing byte and shortened-ETag presentation.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the same test file. Expected: all Proxy Rules LiveView tests pass.

- [ ] **Step 5: Commit the implementation**

```bash
git add apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/proxy_rules_live/index.ex \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs
git commit -m "feat(admin): list ZeroOmega artifact links"
```

### Task 2: Verify the Admin Integration

**Files:**
- Modify only feature files if a feature-caused verification failure requires correction.

- [ ] **Step 1: Run related Proxy Rules and admin tests**

```bash
devenv shell -- mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs
devenv shell -- mix test apps/gsmlg_web/test/gsmlg_web/controllers/zero_omega_rules_controller_test.exs
```

Expected: both test files pass with zero failures.

- [ ] **Step 2: Check scoped formatting and whitespace**

```bash
devenv shell -- mix format --check-formatted \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/proxy_rules_live/index.ex \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/proxy_rules_live_test.exs
git diff --check
git status --short --branch
```

- [ ] **Step 3: Review scope and behavior**

Confirm the diff adds exactly two rows, both say `Proxy + Direct`, both URLs
contain the approved parameters, no exporter is called from LiveView loading,
and the existing six fixed rows and not-ready state remain unchanged.

Do not push, release, deploy, or merge unless separately requested.
