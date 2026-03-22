# Research: Blog Multi-Language Support

**Feature**: 001-blog-multilang
**Date**: 2026-03-19
**Status**: Complete — all NEEDS CLARIFICATION resolved

---

## Decision 1: Background Job Engine

**Decision**: Add **Oban** (hex `oban`) to `apps/gsmlg` deps.

**Rationale**: FR-005/FR-006/FR-011 require queued, retryable, persistent background jobs with lifecycle status tracking. Oban is the standard Elixir job queue, uses the same PostgreSQL Repo, and provides built-in retry with backoff, dead-letter (discarded) state, and Oban Web dashboard visibility. The feature requires durable queuing (survive restarts) and per-job status — Task.Supervisor provides neither.

**Alternatives considered**:
- `Task.Supervisor` — no persistence, no retry, no status visibility. Rejected.
- GenServer polling — not suitable for fan-out to 7+ locales per post. Rejected.
- Oban Pro Workflows — overkill; each translation is a single isolated job, not a DAG. Rejected.

**Configuration**: Single queue `:translations` with `concurrency: 5` (limits simultaneous AI API calls). Max attempts: 3. Unique constraint on `[:blog_id, :locale]` scoped to `[:available, :scheduled, :executing]` states to prevent duplicate translation jobs.

---

## Decision 2: Translation Storage

**Decision**: New `blog_translations` PostgreSQL table via Ecto (not Mnesia, not CouchDB).

**Rationale**: Translations are relational data with a hard FK to `blogs`. They need ACID guarantees (Oban job insertion + translation record creation must be atomic via `Ecto.Multi`). They also need durable storage (outlive node restarts). Mnesia is for ephemeral/distributed state; CouchDB for unstructured documents. PostgreSQL is correct here.

**Alternatives considered**:
- Mnesia — no FK constraints, insufficient for relational data with lifecycle status. Rejected.
- CouchDB — no FK support, ill-suited for structured status tracking. Rejected.
- ETS — ephemeral only, rejected.

---

## Decision 3: Blog Source Locale

**Decision**: Add `source_locale` (string, NOT NULL, default `"zh-Hans"`) column to the existing `blogs` table via a new migration.

**Rationale**: FR-001 requires each post to have a designated source locale. All existing posts are Simplified Chinese (per Assumptions in spec). A single-column migration with a default value covers all existing records with zero data migration required.

**Locale format**: BCP 47 tags — `"en"`, `"zh-Hans"`, `"zh-Hant"`, `"fr"`, `"es"`, `"de"`, `"it"`, `"ja"`. These are stored as plain strings (not atoms) to survive JSON serialization through Oban.

---

## Decision 4: Locale Resolution Strategy

**Decision**: New `GSMLG.Web.Plugs.Locale` plug, inserted in the `:browser` pipeline in `gsmlg_web` router.

**Resolution priority** (FR-003):
1. `?lang=` query parameter → save to session, redirect to clean URL
2. `session[:locale]` → use saved preference
3. `Accept-Language` HTTP header → parse first matching supported locale
4. Config default locale (from `[i18n]` section in TOML)

**Persistence**: Session cookie (not database). No auth required. Survives navigation within session (FR-009). The footer language switcher links set `?lang=LOCALE` which the plug picks up, stores in session, and redirects.

**Gettext integration**: Plug calls `Gettext.put_locale(GSMLG.Web.Gettext, resolved_locale)` and assigns `current_locale` to `conn.assigns` for use in templates and components.

**Note on Phoenix Thinking**: Locale resolution must happen in a Plug (request pipeline), not in LiveView `mount/3`. The blog uses a standard controller (not LiveView), so a plug is the correct mechanism. The footer language switcher is a functional component — it receives `@current_locale` as an assign.

---

## Decision 5: AI Translation Provider Interface

**Decision**: Define a `GSMLG.Translation.Provider` **behaviour** with one callback: `translate/4 :: (title, content, source_locale, target_locale) -> {:ok, %{title, content}} | {:error, reason}`. Concrete implementation is configured via `Application.get_env(:gsmlg, :translation_provider)`.

**Rationale**: The spec is technology-agnostic on which AI service to use (clarified: no provider constraints). A behaviour decouples the Oban worker from the concrete provider, enables test mocking via `Mox`, and allows provider switching via config. Initial concrete implementation TBD at implementation time (e.g., Anthropic Claude API via `:hackney` or `Req`).

**Alternatives considered**:
- Hard-coding a specific provider — couples feature to vendor, complicates testing. Rejected.
- GenServer for provider pooling — premature at this scale (personal blog, ~5 concurrent translations). Deferred.

---

## Decision 6: Config Section

**Decision**: Add `[i18n]` section to `gsmlg_config` schema.

**Fields**:
- `supported_locales` — list of strings, e.g. `["en", "zh-Hans", "zh-Hant", "fr", "es", "de", "it", "ja"]`
- `default_locale` — string, e.g. `"zh-Hans"`

**Applied to**: `Application.put_env(:gsmlg, :i18n, %{supported_locales: [...], default_locale: "zh-Hans"})` in `GSMLG.Config.Setup`.

**Adding a new locale**: Only requires updating `supported_locales` in the TOML file + running the batch task. No code or DB schema changes (FR-002, SC-003).

---

## Decision 7: Atomic Job + Record Creation

**Decision**: Use `Ecto.Multi` + `Oban.insert_all/3` (multi form) for atomic translation setup on post create/update.

**Pattern** (applying Oban Thinking — Oban uses same Repo as app):
```
Ecto.Multi.new()
|> Ecto.Multi.insert(:blog, Blog.changeset(...))
|> Ecto.Multi.insert_all(:translation_records, BlogTranslation, fn %{blog: blog} -> pending_records(blog) end)
|> Oban.insert_all(:jobs, fn %{blog: blog} -> translation_jobs(blog) end)
|> Repo.transaction()
```

This guarantees: if the blog save fails, no translation records or jobs are created. If the DB commit succeeds, Oban jobs are guaranteed visible to workers.

---

## Decision 8: Permanent Failure Detection

**Decision**: In the Oban worker's `perform/1`, check `job.attempt >= job.max_attempts` before returning `{:error, reason}` on the last attempt, then call `Content.mark_translation_failed/2`.

**Rationale**: Avoids external telemetry handlers. The worker is the natural place to detect its own final failure. This keeps the status transitions inside the `GSMLG.Content` context.

---

## Decision 9: Manually-Edited Translation Protection

**Decision**: `blog_translations` table has a `manually_edited` boolean (default `false`). When `Content.update_blog/2` marks translations outdated and queues re-translation, it skips any record where `manually_edited = true` (FR-014, SC-006). Only an explicit admin "re-translate" action bypasses this guard.

---

## Decision 10: Admin Translation Dashboard Placement

**Decision**: New LiveView at `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/blog_live/translation_live/index.ex`, following existing pattern. Accessible at `/admin/blogs/:id/translations`.

**Why LiveView**: Real-time status updates (translation jobs complete asynchronously). The LiveView subscribes to a PubSub topic `"blog_translations:#{blog_id}"` and updates status on job completion.

---

## Existing Infrastructure Confirmed

| Component | Status | Notes |
|-----------|--------|-------|
| Ecto / PostgreSQL | ✅ Done | Migrations applied: `source_locale` on blogs + `blog_translations` table |
| Oban | ✅ Done | Configured in `config/config.exs`; `:translations` queue (concurrency 5); started in supervision tree |
| BlogTranslation schema | ✅ Done | All changesets including `manually_edited` flag |
| Content context | ✅ Done | `create_blog` and `update_blog` use `Ecto.Multi` + `Oban.insert_all`; all translation functions present |
| BlogTranslationWorker | ✅ Done | All error cases: snooze, cancel, fail-on-last-attempt |
| TranslationProvider behaviour | ✅ Done | `GSMLG.Translation.Provider` behaviour; `MockProvider` via Mox for tests |
| ClaudeProvider | ⚠️ Stub | Detects missing API key; `do_translate/5` returns `{:error, :not_implemented}` — needs real implementation |
| Locale plug | ✅ Done | `GSMLG.Web.Plugs.Locale` in `:browser` pipeline; BCP-47 normalization; session persistence |
| Language switcher | ✅ Done | `GSMLG.Web.Components.LanguageSwitcher` in site-wide footer |
| Blog controller | ✅ Done | Locale-aware index + show; translation fallback logic |
| Blog templates | ✅ Done | `show.html.heex` has "AI translated" + "translation in progress" indicators |
| Admin TranslationLive | ✅ Done | Re-translate, edit, save, PubSub real-time updates; `correct_source_locale` event handler present |
| Admin TranslationLive UI | ⚠️ Partial | Template missing UI button to trigger source locale correction |
| Config system | ✅ Done | `[i18n]` section in schema.ex, setup.ex, gsmlg.toml (8 locales configured) |
| Worker tests | ✅ Done | Mox-based; success, cancel, fail-on-last-attempt, snooze, retry cases covered |
| Tesla / Finch | ✅ Available | Both in `apps/gsmlg/mix.exs` deps; Finch started as `GSMLG.Finch` |

## Additional Decisions (Post-Exploration)

### Decision 11: HTTP Client for Anthropic API

**Decision**: Tesla with `Finch` adapter (already in deps) for `ClaudeProvider`.

**Rationale**: `:tesla` and `:finch` are both in `apps/gsmlg/mix.exs`. `Req` is not a current dependency. Tesla with Finch provides middleware stack (JSON encoding, headers, base URL) without adding a new dependency. Finch is started as `GSMLG.Finch` in the supervision tree.

### Decision 12: Claude Model for Translation

**Decision**: `claude-haiku-4-5-20251001` as default, configurable via `Application.get_env(:gsmlg, :claude_translation_model, "claude-haiku-4-5-20251001")`.

**Rationale**: Haiku is fastest and most cost-effective. Translation is mechanical — Opus/Sonnet reasoning quality is not needed for blog translation.

### Decision 13: Mix Task Architecture

**Decision**: Two tasks in `apps/gsmlg/lib/mix/tasks/`:
- `Mix.Tasks.Blog.ClassifyLocales` — one-time heuristic locale detection for existing posts
- `Mix.Tasks.Blog.TranslatePending` — batch job enqueuer for all missing/pending/outdated translations

Both call `Mix.Task.run("app.start")` to boot before using context functions.
