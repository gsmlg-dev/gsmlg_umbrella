# Implementation Plan: Blog Multi-Language Support

**Branch**: `001-blog-multilang` | **Date**: 2026-03-20 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/001-blog-multilang/spec.md`

---

## Summary

Add multi-language display to the blog system with AI translation via Claude (Anthropic API). Visitors see blog content in their preferred language (resolved from query param, cookie, Accept-Language, or default). Translations are generated automatically by Oban background jobs using a pluggable provider. Admins can monitor status, force re-translate, manually edit translations, and correct source locales.

**Current state (2026-03-20)**: ~80% of the feature is already implemented. Schemas, migrations, context functions, Oban worker, locale plug, blog controller, templates, admin dashboard, and language switcher are all in place. What remains: (1) the actual Anthropic API call in `ClaudeProvider`, (2) two mix tasks, (3) source locale correction UI, and (4) test coverage for the new code.

---

## Technical Context

**Language/Version**: Elixir 1.18 / OTP 28
**Framework**: Phoenix 1.8 with LiveView
**Primary Dependencies**: Ecto, Oban 2.18, Tesla + Finch (HTTP), Phoenix.PubSub, phoenix_duskmoon, Mox (test)
**Storage**: PostgreSQL (Ecto). Oban uses same Repo. No Mnesia or CouchDB required for this feature.
**Testing**: ExUnit, Oban.Testing, Mox for provider mocking
**Target Platform**: Linux server (Docker / Burrito release)
**Umbrella Apps affected**: `gsmlg` (core + worker + tasks), `gsmlg_web` (locale plug, templates — all done), `gsmlg_admin_web` (translation dashboard — mostly done)
**UI Technology**: Controller + HEEx templates (public), LiveView (admin dashboard)
**Performance Goals**: Translation jobs queued within 1 min of post save (SC-002); 5 concurrent translation workers (Oban queue config)
**Constraints**: ClaudeProvider must not block the Oban worker process — Tesla call is synchronous but bounded by Oban timeout. Manually-edited translations must never be auto-overwritten (FR-014).
**Scale/Scope**: Personal blog (~50-200 posts), 8 supported locales → ~400-1600 translation records total

---

## Constitution Check

- [x] **Umbrella Architecture**: All logic in correct apps — domain in `gsmlg`, public UI in `gsmlg_web`, admin UI in `gsmlg_admin_web`. No circular deps.
- [x] **Phoenix DuskMoon UI**: Admin dashboard and language switcher use `phoenix_duskmoon` components (`dm_table`, `dm_btn`, `dm_badge`, `dm_page_footer`).
- [x] **Modern Frontend Workflow**: Bun + TailwindCSS asset pipeline unchanged.
- [x] **OTP Distribution Model**: Oban is in the core `gsmlg` app, accessible to both standalone and distributed deployments. No commander-specific changes needed.
- [x] **Test-First Development**: Test tasks listed BEFORE their implementation counterparts in each phase.

**Complexity Justification**: None required — no constitution violations.

---

## Project Structure

### Documentation (this feature)

```text
specs/001-blog-multilang/
├── plan.md              ← This file
├── research.md          ← Decisions: HTTP client, model, prompt, mix tasks
├── data-model.md        ← Schemas, state machine, context functions
├── quickstart.md        ← Dev workflow, file inventory
├── contracts/           ← (Internal routes, not REST API)
└── tasks.md             ← Phase 2 output (/speckit.tasks)
```

### Source Code (affected paths)

```text
apps/
├── gsmlg/
│   ├── lib/gsmlg/
│   │   ├── translation/
│   │   │   ├── provider.ex                    ✅ Done
│   │   │   └── claude_provider.ex             ⚠️ Needs do_translate impl
│   │   └── workers/
│   │       └── blog_translation_worker.ex     ✅ Done
│   ├── lib/mix/tasks/blog/
│   │   ├── classify_locales.ex                ❌ New file needed
│   │   └── translate_pending.ex               ❌ New file needed
│   └── test/gsmlg/
│       ├── content_test.exs                   ⚠️ Needs translation coverage
│       ├── translation/
│       │   └── claude_provider_test.exs       ❌ New test needed
│       ├── workers/
│       │   └── blog_translation_worker_test.exs ✅ Done
│       └── tasks/
│           ├── classify_locales_test.exs       ❌ New test needed
│           └── translate_pending_test.exs      ❌ New test needed
│
├── gsmlg_web/
│   └── test/gsmlg_web/
│       ├── plugs/
│       │   └── locale_test.exs                ❌ New test needed
│       └── controllers/
│           └── blog_controller_test.exs        ⚠️ Needs locale coverage
│
└── gsmlg_admin_web/
    ├── lib/gsmlg_admin_web/live/blog_live/
    │   └── translation_live/
    │       └── index.html.heex                 ⚠️ Needs source locale correction UI
    └── test/gsmlg_admin_web/
        └── live/
            └── blog_live/
                └── translation_live_test.exs   ❌ New test needed
```

---

## Complexity Tracking

> No constitution violations. No entries required.

---

## Phase 0: Research

**Status**: ✅ Complete. See [research.md](research.md).

Key decisions resolved:
- HTTP client: Tesla + Finch (already in deps)
- Claude model: `claude-haiku-4-5-20251001` (configurable)
- Prompt structure: single-turn Messages API with JSON response
- Mix task placement: `apps/gsmlg/lib/mix/tasks/blog/`
- Locale heuristic: Unicode CJK range `\u4e00–\u9fff` → `zh-Hans`, else `en`

---

## Phase 1: Design & Contracts

**Status**: ✅ Complete. See [data-model.md](data-model.md) and [quickstart.md](quickstart.md).

- All schemas and migrations are applied.
- All context functions are implemented.
- All routes are configured.
- Oban is configured and started.

---

## Phase 2: Implementation Tasks

> **IMPORTANT**: Per Constitution Principle V (Test-First Development), tests MUST be written before implementation for each component. Tasks are ordered: test first → implementation.

### Group A: Claude Provider (Highest Priority — Unblocks all translation)

**A1 — [TEST] ClaudeProvider: write failing tests**

Write `apps/gsmlg/test/gsmlg/translation/claude_provider_test.exs` verifying:
- Returns `{:error, :not_configured}` when API key is empty string
- Returns `{:ok, %{title: _, content: _}}` for a successful mock response (bypass network with Tesla mock/test adapter)
- Returns `{:error, :rate_limited}` on HTTP 429
- Returns `{:error, reason}` on HTTP 5xx
- Returns `{:error, :json_parse_error}` when response JSON is malformed

*These tests will fail until A2 is complete.*

**A2 — [IMPL] ClaudeProvider: implement `do_translate/5`**

File: `apps/gsmlg/lib/gsmlg/translation/claude_provider.ex`

Implement `do_translate/5` using Tesla + Finch:
- Build Tesla client: `BaseUrl("https://api.anthropic.com")`, `JSON` middleware, headers `anthropic-version: 2023-06-01`, `x-api-key: api_key`; `Adapter.Finch` with `name: GSMLG.Finch`
- `POST /v1/messages` with model `claude-haiku-4-5-20251001` (or configured override)
- Prompt: system sets context (professional translator, source → target language names, preserve Markdown, return JSON); user message contains title + content
- Special case: if source or target is `"zh-Hans"`, use "Simplified Chinese"; if `"zh-Hant"`, use "Traditional Chinese"
- Parse `response.content[0].text` → decode JSON → extract `%{"title" => _, "content" => _}`
- Map errors: `{:error, :rate_limited}` on 429; `{:error, :not_configured}` on missing key; `{:error, :json_parse_error}` on bad JSON; `{:error, reason}` otherwise
- Language names: read from a private `@locale_names` map (same as `LanguageSwitcher` component)

---

### Group B: Mix Tasks

**B1 — [TEST] `classify_locales` task: write failing tests**

Write `apps/gsmlg/test/gsmlg/tasks/classify_locales_test.exs` verifying:
- CJK content detected as `"zh-Hans"`
- Latin content detected as `"en"`
- `--dry-run` prints changes but does not update DB
- `--confirm` updates `source_locale` in DB
- Summary output counts posts per detected locale

**B2 — [IMPL] `mix blog.classify_locales`**

File: `apps/gsmlg/lib/mix/tasks/blog/classify_locales.ex`

- `use Mix.Task`
- Call `Mix.Task.run("app.start")` before touching the DB
- Load all blogs via `GSMLG.Content.list_blogs()`
- For each blog, run `detect_locale(blog.title <> " " <> blog.content)`:
  ```elixir
  defp detect_locale(text) do
    if String.match?(text, ~r/[\u4e00-\u9fff]/u), do: "zh-Hans", else: "en"
  end
  ```
- Print summary table: `[id] [slug] [detected: zh-Hans/en]`
- With `--dry-run` (default): only print, no writes
- With `--confirm`: call `GSMLG.Content.update_blog(blog, %{source_locale: detected})`
- Print final summary: `N posts updated`

**B3 — [TEST] `translate_pending` task: write failing tests**

Write `apps/gsmlg/test/gsmlg/tasks/translate_pending_test.exs` verifying:
- Enqueues Oban jobs for posts with no translation record for a supported locale
- Enqueues jobs for posts with `status: "outdated"` or `status: "failed"` translations
- Skips posts with `status: "completed"` or `status: "in_progress"` translations
- Skips manually-edited translations
- `--dry-run` prints planned jobs but does not insert
- `--confirm` inserts Oban jobs

**B4 — [IMPL] `mix blog.translate_pending`**

File: `apps/gsmlg/lib/mix/tasks/blog/translate_pending.ex`

- Call `Mix.Task.run("app.start")`
- Load supported locales from `Application.get_env(:gsmlg, :i18n)[:supported_locales]`
- Call `GSMLG.Content.batch_pending_translations(supported_locales)` → `[{blog_id, locale, source_locale}]`
- Print list of planned jobs
- With `--dry-run`: only print
- With `--confirm`: call `Oban.insert_all(jobs)` where jobs are `BlogTranslationWorker.new(%{...})`

---

### Group C: Admin UI Completion

**C1 — [TEST] Admin TranslationLive: write failing tests**

Write `apps/gsmlg_admin_web/test/gsmlg_admin_web/live/blog_live/translation_live_test.exs` verifying:
- Dashboard loads and shows translation status for each locale
- "Re-translate" button queues an Oban job and updates status in UI
- "Edit" button shows inline form; "Save" updates translation and sets `manually_edited: true`
- "Cancel" hides inline form without changes
- `correct_source_locale` event updates the blog's `source_locale`
- Source locale correction UI is present (form/button exists in template)
- PubSub broadcast of `{:translation_updated, id, locale, status}` updates UI without page reload

**C2 — [IMPL] Admin TranslationLive: source locale correction UI**

File: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/blog_live/translation_live/index.html.heex`

Add a source locale correction control below the current "Source locale: `<locale>`" display:
- A `<select>` element with all supported locales as options, pre-selected to `@blog.source_locale`
- A "Save" button that sends `phx-click="correct_source_locale"` with the selected locale value
- Style using existing `dm_btn`, `dm_select` (or equivalent) components
- Show a warning when source locale is changed: "All non-manually-edited translations will be marked outdated"

---

### Group D: Test Coverage Gaps

**D1 — [TEST] Content context: translation functions**

Extend `apps/gsmlg/test/gsmlg/content_test.exs` to cover:
- `create_blog/1` enqueues Oban jobs for all target locales (use `assert_enqueued/2` from `Oban.Testing`)
- `update_blog/2` with content change marks non-manually-edited translations as `"outdated"` and enqueues new jobs
- `update_blog/2` with no content change does not mark translations as outdated
- `update_blog/2` preserves `manually_edited: true` translations
- `batch_pending_translations/1` returns `{blog_id, locale, source_locale}` for posts missing translations for a given locale
- `batch_pending_translations/1` returns entries for `"outdated"` and `"failed"` translations but not `"completed"` or `"in_progress"`

**D2 — [TEST] Locale plug**

Create `apps/gsmlg_web/test/gsmlg_web/plugs/locale_test.exs` verifying:
- `?lang=fr` query param sets `conn.assigns.current_locale` to `"fr"` and saves to session
- Session `:locale` takes precedence over `Accept-Language` header
- `Accept-Language: zh-CN` maps to `"zh-Hans"`
- `Accept-Language: zh-TW` maps to `"zh-Hant"`
- `Accept-Language: zh-SG` maps to `"zh-Hans"`
- `Accept-Language: zh-HK` maps to `"zh-Hant"`
- Unsupported locale falls back to config default
- No session / no header resolves to config default

**D3 — [TEST] Blog controller: locale-aware rendering**

Extend `apps/gsmlg_web/test/gsmlg_web/controllers/blog_controller_test.exs`:
- `GET /blogs` with `?lang=en` header serves translated titles for blogs with completed English translations
- `GET /blogs` falls back to source title when no translation is completed for the locale
- `GET /blogs/:slug` with `?lang=fr` shows French translation when `status: "completed"`
- `GET /blogs/:slug` shows "translation in progress" indicator when `status: "in_progress"`
- `GET /blogs/:slug` shows "AI translated" indicator when showing a completed translation
- `GET /blogs/:slug` shows no indicator when serving source locale content

---

## Implementation Order

```
A1 → A2  (ClaudeProvider — unblocks real translations)
B1 → B2  (classify_locales task)
B3 → B4  (translate_pending task)
C1 → C2  (admin UI completion)
D1       (content context tests — can run in parallel with A/B/C)
D2       (locale plug tests — can run in parallel)
D3       (blog controller tests — can run in parallel)
```

Groups A, B, C, D are independent of each other at the group level and can be parallelised. Within each group, test (A1) must precede implementation (A2).

---

## Constitution Re-Check (Post-Design)

All gates pass:
- ✅ Umbrella Architecture: no boundary violations
- ✅ Phoenix DuskMoon UI: source locale correction will use `dm_btn` and form components
- ✅ Modern Frontend Workflow: no new JS/CSS dependencies
- ✅ OTP Distribution Model: Oban in `gsmlg` core, accessible everywhere
- ✅ Test-First Development: every implementation task is preceded by a test task

---

## Definition of Done

- [ ] `ClaudeProvider.do_translate/5` implemented; all provider tests pass
- [ ] `mix blog.classify_locales` works on dev database; existing posts classified
- [ ] `mix blog.translate_pending` enqueues jobs for all uncovered locales
- [ ] Admin translation dashboard shows source locale correction UI
- [ ] All new tests pass: `mix test apps/gsmlg/test/ apps/gsmlg_web/test/ apps/gsmlg_admin_web/test/`
- [ ] `mix compile --warnings-as-errors` clean
- [ ] `mix credo --strict` clean
- [ ] Real translation end-to-end tested: create a post → jobs enqueued → worker runs → translation appears
