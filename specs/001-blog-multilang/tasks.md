# Tasks: Blog Multi-Language Support

**Input**: Design documents from `/specs/001-blog-multilang/`
**Prerequisites**: plan.md ✓, spec.md ✓, research.md ✓, data-model.md ✓, quickstart.md ✓
**Codebase verified**: 2026-03-20 — ~80% already implemented

**Tests**: Included per Constitution §V (Test-First Development is NON-NEGOTIABLE).

**Organization**: Tasks grouped by user story. Completed work is marked `[x]`. Only the remaining tasks (`[ ]`) need implementation.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no unresolved dependencies)
- **[Story]**: User story label (US1–US5) from spec.md
- Exact file paths are included in every task description

---

## Phase 1: Setup — ✅ COMPLETE

All infrastructure is in place.

- [x] T001 Add `{:oban, "~> 2.18"}` to deps in `apps/gsmlg/mix.exs`
- [x] T002 [P] Configure Oban in `config/config.exs`: `:translations` queue with `concurrency: 5`; test config uses `testing: :inline`
- [x] T003 [P] Run `mix oban.install`; migration `20260320000001_create_oban_jobs_table.exs` committed

---

## Phase 2: Foundational — ✅ COMPLETE

Database schema, config system, and domain layer are all in place.

- [x] T004 Add `@i18n_schema` to `apps/gsmlg_config/lib/gsmlg/config/schema.ex` (fields: `supported_locales`, `default_locale`)
- [x] T005 [P] Apply `:i18n` config in `apps/gsmlg_config/lib/gsmlg/config/setup.ex`
- [x] T006 [P] Add `[i18n]` section to `apps/gsmlg_config/priv/gsmlg.toml` (8 locales) and `apps/gsmlg_config/priv/gsmlg.test.toml`
- [x] T007 Migration `20260320000002_add_source_locale_to_blogs.exs` — adds `source_locale` column
- [x] T008 [P] Migration `20260320000003_create_blog_translations.exs` — `blog_translations` table with indexes
- [x] T009 Update `apps/gsmlg/lib/gsmlg/content/blog.ex`: `source_locale` field + changeset
- [x] T010 [P] Create `apps/gsmlg/lib/gsmlg/content/blog_translation.ex`: full schema with all 6 changesets including `manually_edited` flag
- [x] T011 [P] Create `apps/gsmlg/lib/gsmlg/translation/provider.ex`: `@callback translate/4` behaviour
- [x] T012 Add all translation functions to `apps/gsmlg/lib/gsmlg/content.ex` including `batch_pending_translations/1`
- [x] T013 [P] Add `blog_translation_fixture/1` to `apps/gsmlg/test/support/fixtures/content_fixtures.ex`

---

## Phase 3: US1 — Read Blog in Preferred Language — ✅ COMPLETE

- [x] T014 [P] [US1] `apps/gsmlg_web/lib/gsmlg/web/plugs/locale.ex` — BCP-47 normalization, session persistence
- [x] T015 [P] [US1] `plug GSMLG.Web.Plugs.Locale` in `:browser` pipeline in `apps/gsmlg_web/lib/gsmlg/web/router.ex`
- [x] T016 [US1] `apps/gsmlg_web/lib/gsmlg/web/controllers/blog_controller.ex` — locale-aware index + show
- [x] T017 [US1] `apps/gsmlg_web/lib/gsmlg/web/controllers/blog_html/show.html.heex` — translation fallback
- [x] T018 [US1] `apps/gsmlg_web/lib/gsmlg/web/controllers/blog_html/index.html.heex` — translated titles

---

## Phase 4: US2 — Language Switcher UI — ✅ COMPLETE

- [x] T019 [US2] `apps/gsmlg_web/lib/gsmlg/web/components/language_switcher.ex` — native language names, active state
- [x] T020 [US2] `apps/gsmlg_web/lib/gsmlg/web/components/layouts/root.html.heex` — switcher in site-wide footer

---

## Phase 5: US3 — AI Translation Indicators — ✅ COMPLETE

- [x] T021 [US3] `apps/gsmlg_web/lib/gsmlg/web/controllers/blog_html/show.html.heex` — "AI translated" + "translation in progress" indicators

---

## Phase 6: US4 — Automatic Background Translation — ✅ COMPLETE

- [x] T022 [US4] `apps/gsmlg/lib/gsmlg/translation/claude_provider.ex` — provider skeleton with API key detection
- [x] T023 [US4] `apps/gsmlg/lib/gsmlg/workers/blog_translation_worker.ex` — full worker with snooze/cancel/fail-on-last-attempt
- [x] T024 [US4] `apps/gsmlg/lib/gsmlg/content.ex` — `create_blog/1` uses `Ecto.Multi` + `Oban.insert_all`
- [x] T025 [US4] `apps/gsmlg/lib/gsmlg/content.ex` — `update_blog/2` marks outdated + re-enqueues
- [x] T026 [P] [US4] `apps/gsmlg/test/support/mocks.ex` — `Mox.defmock(GSMLG.Translation.MockProvider, ...)`
- [x] T027 [P] [US4] `apps/gsmlg/test/gsmlg/workers/blog_translation_worker_test.exs` — full Mox-based worker tests

---

## Phase 7: US5 — Admin Translation Dashboard — ✅ MOSTLY COMPLETE

- [x] T028 [US5] `apps/gsmlg_admin_web/lib/gsmlg/admin_web/router.ex` — `/blogs/:id/translations` route
- [x] T029 [US5] `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/blog_live/translation_live/index.ex` — full LiveView with re-translate, manual edit, PubSub subscription, `correct_source_locale` event handler
- [x] T030 [US5] `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/blog_live/translation_live/index.html.heex` — status table with re-translate + edit actions

---

## Phase 8: Remaining Work — ⚠️ NEEDS IMPLEMENTATION

**These are the only tasks that remain. All tasks above are complete.**

### Group A: Claude Provider (Unblocks real translations)

**⚠️ Write test FIRST — must FAIL before implementation**

- [ ] T031 [P] [US4] Write failing test for `ClaudeProvider` in `apps/gsmlg/test/gsmlg/translation/claude_provider_test.exs`: test `{:error, :not_configured}` when API key blank; use Tesla mock adapter to test successful response returns `{:ok, %{title: _, content: _}}`; test HTTP 429 returns `{:error, :rate_limited}`; test malformed JSON returns `{:error, :json_parse_error}` *(must fail before T032)*
- [ ] T032 [US4] Implement `do_translate/5` in `apps/gsmlg/lib/gsmlg/translation/claude_provider.ex`: build Tesla client with `BaseUrl("https://api.anthropic.com")`, `JSON` middleware, headers `anthropic-version: 2023-06-01` + `x-api-key`, `Adapter.Finch` (name: `GSMLG.Finch`); `POST /v1/messages` with model `Application.get_env(:gsmlg, :claude_translation_model, "claude-haiku-4-5-20251001")`; system prompt specifies professional translator, source→target language names, preserve Markdown, return JSON with `title` and `content` keys; parse `response.content[0].text`; map HTTP 429 → `:rate_limited`, bad JSON → `:json_parse_error`

### Group B: Mix Tasks (Batch operations)

**⚠️ Write tests FIRST**

- [ ] T033 [P] Write failing tests for classify_locales task in `apps/gsmlg/test/gsmlg/tasks/classify_locales_test.exs`: test CJK content detected as `"zh-Hans"`; test Latin content detected as `"en"`; test `--dry-run` does not write to DB; test `--confirm` updates `source_locale` *(must fail before T034)*
- [ ] T034 [P] Create `apps/gsmlg/lib/mix/tasks/blog/classify_locales.ex` (`Mix.Tasks.Blog.ClassifyLocales`): `use Mix.Task`; run `Mix.Task.run("app.start")`; load all blogs via `GSMLG.Content.list_blogs()`; for each blog apply `detect_locale/1` → `~r/[\u4e00-\u9fff]/u` match = `"zh-Hans"`, else `"en"`; print summary table `[id] [slug] [current_source_locale] → [detected]`; with `--confirm` call `Content.update_blog(blog, %{source_locale: detected})`; default is `--dry-run`
- [ ] T035 [P] Write failing tests for translate_pending task in `apps/gsmlg/test/gsmlg/tasks/translate_pending_test.exs`: test enqueues jobs for posts with no translation record for a locale; test enqueues for `"outdated"` and `"failed"` status; test skips `"completed"` and `"in_progress"`; test `--dry-run` does not insert jobs *(must fail before T036)*
- [ ] T036 [P] Create `apps/gsmlg/lib/mix/tasks/blog/translate_pending.ex` (`Mix.Tasks.Blog.TranslatePending`): `use Mix.Task`; run `Mix.Task.run("app.start")`; read `supported_locales` from `Application.get_env(:gsmlg, :i18n)[:supported_locales]`; call `GSMLG.Content.batch_pending_translations(supported_locales)` → `[%{blog_id, locale, source_locale}]`; print planned jobs; with `--confirm` call `Oban.insert_all(jobs)` where jobs are `GSMLG.Workers.BlogTranslationWorker.new(%{"blog_id" => ..., "locale" => ..., "source_locale" => ...})`; default is `--dry-run`

### Group C: Admin UI Completion

**⚠️ Write test FIRST**

- [ ] T037 [P] [US5] Write failing LiveView test in `apps/gsmlg_admin_web/test/gsmlg_admin_web/live/blog_live/translation_live_test.exs`: test dashboard loads; test "re-translate" event inserts Oban job and status resets; test manual edit saves `manually_edited: true`; test source locale correction select element exists and `correct_source_locale` event updates `blog.source_locale` *(must fail before T038)*
- [ ] T038 [US5] Add source locale correction UI to `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/blog_live/translation_live/index.html.heex`: replace the plain `<p>Source locale: <strong><%= @blog.source_locale %></strong></p>` display with a form containing a `<select>` element showing all supported locales (pre-selected to `@blog.source_locale`) and a "Save" `dm_btn` that triggers `phx-click="correct_source_locale"` with the selected value; add a small warning text "Changing source locale will mark all auto-generated translations as outdated"

### Group D: Test Coverage

**Run in parallel with Groups A, B, C — independent test files**

- [ ] T039 [P] Extend `apps/gsmlg/test/gsmlg/content_test.exs` with translation coverage: test `create_blog/1` enqueues one `BlogTranslationWorker` job per non-source locale (use `assert_enqueued` from `Oban.Testing`); test `update_blog/2` with content change marks non-manually_edited translations `"outdated"` and re-enqueues; test `update_blog/2` preserves `manually_edited: true` translations; test `batch_pending_translations/1` returns entries for missing + outdated + failed, skips completed + in_progress
- [ ] T040 [P] Create `apps/gsmlg_web/test/gsmlg_web/plugs/locale_test.exs`: test `?lang=fr` sets `current_locale` to `"fr"` and saves to session; test session value beats `Accept-Language`; test `zh-CN` → `"zh-Hans"`, `zh-TW` → `"zh-Hant"`, `zh-SG` → `"zh-Hans"`, `zh-HK` → `"zh-Hant"`; test unsupported locale falls back to config default; test no header/session resolves to default
- [ ] T041 [P] Extend `apps/gsmlg_web/test/gsmlg_web/controllers/blog_controller_test.exs`: test `GET /blogs/:slug?lang=fr` shows French translation when `status: "completed"`; test shows "AI translated" indicator for completed non-source translation; test shows "translation in progress" indicator when `status: "in_progress"`; test no indicator when locale = source_locale; test fallback to source content when no translation exists

---

## Final Phase: Quality Gates

- [ ] T042 [P] Run `mix compile --warnings-as-errors` across all affected apps: `apps/gsmlg`, `apps/gsmlg_web`, `apps/gsmlg_admin_web`; fix any warnings
- [ ] T043 [P] Run `mix credo --strict` across affected apps; fix violations
- [ ] T044 [P] Run `mix format`; verify `mix format --check-formatted` passes
- [ ] T045 Run full test suite: `mix test apps/gsmlg/test/ apps/gsmlg_web/test/ apps/gsmlg_admin_web/test/` — all pass
- [ ] T046 End-to-end smoke test per `quickstart.md`: start `mix phx.server`; classify locales with `mix blog.classify_locales --dry-run`; view `/blogs?lang=fr` (fallback to source); create a test post → Oban job enqueued; run `Oban.drain_queue(:translations)` in iex → translation appears; verify footer language switcher persists selection

---

## Dependencies & Execution Order

### What's Complete

Phases 1–7 are done. All schema, config, context, worker, plug, templates, and admin dashboard code exists.

### What Remains (Phase 8 tasks only)

```
Phase 8 execution order:

  T031 → T032   (ClaudeProvider: test first, then implement)
  T033 → T034   (classify_locales: test first, then implement)
  T035 → T036   (translate_pending: test first, then implement)
  T037 → T038   (admin source locale UI: test first, then implement)

  T039, T040, T041 can start immediately (parallel test coverage)

Final Phase after all Phase 8 tasks:
  T042, T043, T044 (parallel quality gates)
  T045 (full test suite)
  T046 (smoke test)
```

### Parallel Opportunities in Phase 8

All 4 groups (A, B, C, D) are independent — they touch different files with no shared state:

```
Agent/Dev 1: T031 → T032 (ClaudeProvider API call)
Agent/Dev 2: T033 → T034 (classify_locales task)
Agent/Dev 3: T035 → T036 (translate_pending task)
Agent/Dev 4: T037 → T038 (admin source locale UI)
Agent/Dev 5: T039 + T040 + T041 (parallel test coverage — all different files)
```

---

## Implementation Strategy

### Minimum Remaining Work (MVP path through Phase 8)

The system is already deployable in its current state — it displays blogs in the visitor's locale with source-content fallback. The `ClaudeProvider` stub means no AI translations run, but the feature is fully functional architecturally.

1. **T031 → T032** (ClaudeProvider): Unlocks real AI translations — highest value
2. **T037 → T038** (Admin UI): Completes the source locale correction workflow
3. **T039 + T040 + T041** (Tests): Closes test coverage gaps
4. **T033 → T036** (Mix tasks): Enables initial data setup for existing posts

### Full Completion Path

```
T031 → T032  AND  T033 → T034  AND  T035 → T036  AND  T037 → T038  (parallel)
+
T039 + T040 + T041  (parallel)
→ T042 + T043 + T044  (parallel quality gates)
→ T045 (full test run)
→ T046 (smoke test)
```

---

## Notes

- `[P]` = different files, no dependencies on in-progress sibling tasks
- `[US?]` maps each task to its user story for traceability
- Constitution §V: test tasks (T031, T033, T035, T037, T039, T040, T041) must be written and verified RED before their corresponding implementation tasks
- `Oban.Testing.assert_enqueued/2` for verifying job enqueueing in T039
- Tesla mock adapter in tests for ClaudeProvider (T031): use `Tesla.Mock` adapter in test config or `Tesla.Mock.mock/1`
- `Mox.expect/3` + `verify_on_exit!/1` already configured for `GSMLG.Translation.MockProvider`
- Never query in `mount/3` in LiveView — data loading stays in `handle_params/3`
- Mix tasks must call `Mix.Task.run("app.start")` to boot OTP application before touching the DB
- String key pattern matching in Oban worker `perform/1`: `%{"blog_id" => id}` not `%{blog_id: id}` (JSON atoms → strings)
