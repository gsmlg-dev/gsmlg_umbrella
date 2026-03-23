# Quickstart: Blog Multi-Language Support

**Feature branch**: `001-blog-multilang`

---

## Prerequisites

```bash
# Ensure you are on the feature branch
git checkout 001-blog-multilang

# Install dependencies (all existing in mix.exs — no new deps needed)
mix deps.get

# Migrate (migrations already written and applied on this branch)
mix ecto.migrate

# Classify source locales for existing posts (one-time)
mix blog.classify_locales --dry-run
mix blog.classify_locales --confirm
```

---

## Key Files to Know

### Core Domain (gsmlg)

| File | Status | Purpose |
|------|--------|---------|
| `apps/gsmlg/lib/gsmlg/content/blog.ex` | ✅ Done | Blog schema with `source_locale` |
| `apps/gsmlg/lib/gsmlg/content/blog_translation.ex` | ✅ Done | Translation schema, all changesets |
| `apps/gsmlg/lib/gsmlg/content.ex` | ✅ Done | Full context with create/update/translation functions |
| `apps/gsmlg/lib/gsmlg/workers/blog_translation_worker.ex` | ✅ Done | Oban worker, all error cases |
| `apps/gsmlg/lib/gsmlg/translation/provider.ex` | ✅ Done | Provider behaviour |
| `apps/gsmlg/lib/gsmlg/translation/claude_provider.ex` | ⚠️ Stub | **Needs**: real Anthropic API call via Tesla |
| `apps/gsmlg/lib/mix/tasks/blog/classify_locales.ex` | ❌ Needed | One-time locale detection for existing posts |
| `apps/gsmlg/lib/mix/tasks/blog/translate_pending.ex` | ❌ Needed | Batch translation job enqueuer |

### Web App (gsmlg_web)

| File | Status | Purpose |
|------|--------|---------|
| `apps/gsmlg_web/lib/gsmlg/web/plugs/locale.ex` | ✅ Done | Locale resolution, BCP-47 normalization |
| `apps/gsmlg_web/lib/gsmlg/web/components/language_switcher.ex` | ✅ Done | Footer language switcher |
| `apps/gsmlg_web/lib/gsmlg/web/components/layouts/root.html.heex` | ✅ Done | Language switcher in footer |
| `apps/gsmlg_web/lib/gsmlg/web/controllers/blog_controller.ex` | ✅ Done | Locale-aware controller |
| `apps/gsmlg_web/lib/gsmlg/web/controllers/blog_html/show.html.heex` | ✅ Done | AI translated + in-progress indicators |
| `apps/gsmlg_web/lib/gsmlg/web/controllers/blog_html/index.html.heex` | ✅ Done | Translated titles in index |

### Admin Web (gsmlg_admin_web)

| File | Status | Purpose |
|------|--------|---------|
| `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/blog_live/translation_live/index.ex` | ✅ Done | Translation dashboard LiveView |
| `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/blog_live/translation_live/index.html.heex` | ⚠️ Partial | **Needs**: source locale correction UI button |
| `apps/gsmlg_admin_web/lib/gsmlg/admin_web/router.ex` | ✅ Done | `/blogs/:id/translations` route |

---

## Running Tests

```bash
# All tests for affected apps
mix test apps/gsmlg/test/
mix test apps/gsmlg_web/test/gsmlg_web/controllers/blog_controller_test.exs
mix test apps/gsmlg_web/test/gsmlg_web/plugs/locale_test.exs
mix test apps/gsmlg_admin_web/test/

# Run with coverage
mix test --cover apps/gsmlg/test/

# Run a single test by line
mix test apps/gsmlg/test/gsmlg/content_test.exs:42
```

---

## Local Dev Workflow

```bash
# Start the dev server (web:4110, admin:4111)
mix phx.server

# View blog at:
# http://localhost:4110/blogs

# Test locale switching:
# http://localhost:4110/blogs?lang=fr
# http://localhost:4110/blogs?lang=zh-Hans

# Admin translation dashboard:
# http://localhost:4111/admin/blogs/:id/translations

# Manually trigger batch translation (from iex):
iex -S mix
iex> GSMLG.Content.batch_pending_translations(Application.get_env(:gsmlg, :i18n)[:supported_locales])
iex> # Then enqueue Oban jobs for each returned {blog_id, locale}
```

---

## Adding a New Language

1. Update `[i18n]` section in `apps/gsmlg_config/priv/gsmlg.toml`:
   ```toml
   supported_locales = ["zh-Hans", "en", "zh-Hant", "fr", "es", "de", "it", "ja", "ko"]
   ```
2. Restart the application (config is loaded at boot).
3. Run the batch task via admin UI or `iex` to queue translations for the new locale.

No code changes. No database migrations. (SC-003)

---

## Oban Dashboard

Oban Web (if configured) is accessible at the admin app. Translation jobs appear in the `:translations` queue. Failed jobs can be retried from the dashboard.

---

## Architecture at a Glance

```
Visitor request
    ↓
LocalePlug (resolves locale: ?lang → session → Accept-Language → default)
    ↓
BlogController.show/2
    ↓
Content.get_blog_by_slug/1
    + Content.get_translation(blog.id, resolved_locale)
    ↓
blog_html/show.html.heex
    ├── if translation.status == "completed" → show translated title/content
    ├── if translation.status in [:pending, :in_progress] → show source + "translation in progress"
    └── if no translation → show source (fallback)

Blog created/updated
    ↓
Content.create_blog/1 or update_blog/2
    ↓ (Ecto.Multi + Oban.insert_all)
BlogTranslationWorker enqueued × N locales
    ↓
BlogTranslationWorker.perform/1
    ↓
Translation.Provider.translate(title, content, source, target)
    ↓
Content.complete_translation (or fail/retry)
    ↓
PubSub broadcast → admin LiveView updates in real time
```
