# Data Model: Blog Multi-Language Support

**Feature**: 001-blog-multilang
**Date**: 2026-03-19 (verified against codebase 2026-03-20)

---

## Schema Changes

### 1. Modify: `blogs` table

**Migration**: Add `source_locale` column.

```sql
ALTER TABLE blogs
  ADD COLUMN source_locale VARCHAR(20) NOT NULL DEFAULT 'zh-Hans';
```

**Ecto migration** (`add_source_locale_to_blogs`):

```elixir
def change do
  alter table(:blogs) do
    add :source_locale, :string, null: false, default: "zh-Hans"
  end
end
```

**Elixir schema update** (`GSMLG.Content.Blog`):

```elixir
field :source_locale, :string, default: "zh-Hans"
```

**Changeset update**: `source_locale` included in `cast/2`; validated as non-empty string.

---

### 2. New: `blog_translations` table

**Migration**: `create_blog_translations`

```elixir
def change do
  create table(:blog_translations) do
    add :blog_id, references(:blogs, on_delete: :delete_all), null: false
    add :locale, :string, null: false
    add :title, :string
    add :content, :text
    add :status, :string, null: false, default: "pending"
    add :manually_edited, :boolean, null: false, default: false

    timestamps()
  end

  create unique_index(:blog_translations, [:blog_id, :locale])
  create index(:blog_translations, [:locale])
  create index(:blog_translations, [:status])
end
```

**Ecto schema** (`GSMLG.Content.BlogTranslation`):

```elixir
schema "blog_translations" do
  field :locale, :string
  field :title, :string
  field :content, :text
  field :status, :string, default: "pending"
  field :manually_edited, :boolean, default: false

  belongs_to :blog, GSMLG.Content.Blog

  timestamps()
end
```

**Valid status values**: `"pending"` | `"in_progress"` | `"completed"` | `"failed"` | `"outdated"`

**Changesets**:

| Changeset | Purpose | Required fields |
|-----------|---------|-----------------|
| `pending_changeset/2` | Created when job is queued | blog_id, locale |
| `progress_changeset/2` | Worker started | status → "in_progress" |
| `complete_changeset/2` | Worker succeeded | title, content, status → "completed" |
| `fail_changeset/1` | Max attempts exhausted | status → "failed" |
| `outdated_changeset/1` | Source post updated | status → "outdated" |
| `admin_edit_changeset/2` | Admin manually edits | title, content, manually_edited → true |

---

## Entity Relationships

```
blogs (existing)
  id PK
  slug
  title
  date
  author
  content
  source_locale  ← NEW
  inserted_at
  updated_at
      |
      | 1 : many
      ↓
blog_translations (NEW)
  id PK
  blog_id FK → blogs.id (CASCADE DELETE)
  locale          -- BCP 47 tag: "en", "zh-Hans", "zh-Hant", "fr", etc.
  title           -- NULL until translation completes
  content         -- NULL until translation completes
  status          -- "pending" | "in_progress" | "completed" | "failed" | "outdated"
  manually_edited -- protected from automated overwrite when true
  inserted_at
  updated_at

  UNIQUE (blog_id, locale)
```

---

## State Machine: Translation Status

```
                    post created / batch task
                           ↓
                       [pending]
                           ↓  Oban job starts
                    [in_progress]
                      ↙        ↘
              (success)          (error, attempt < max)
                 ↓                    ↓
           [completed]          (retry → in_progress)
               ↑   ↓                  ↓ (attempt = max)
    post updated   post updated    [failed]
    (manual edit)  (auto-detected)    ↓ admin re-triggers
    → stays        → [outdated]    [pending]
      completed      ↓
    (manually_     [pending] → [in_progress] → [completed/failed]
    edited=true)
```

**Key invariants**:
- A `blog_translations` record always has a `blog_id` + `locale` combination that is unique.
- `title` and `content` are NULL until `status = "completed"` or `"outdated"` (outdated records retain their last completed content for fallback display).
- `manually_edited = true` records are skipped by auto-outdating and batch re-translation.

---

## Context Functions Added to `GSMLG.Content`

| Function | Description |
|----------|-------------|
| `list_translations/1` | All translations for a blog_id |
| `list_translations_by_status/1` | All translations with given status |
| `get_translation/2` | `(blog_id, locale)` → Translation or nil |
| `get_translation!/2` | Raises on missing |
| `create_pending_translations/2` | `(blog, locales)` → `[{:ok, t}]` |
| `mark_translation_in_progress/1` | status → "in_progress" |
| `complete_translation/3` | `(translation, title, content)` → completed |
| `mark_translation_failed/1` | status → "failed" |
| `mark_translation_outdated/1` | status → "outdated" |
| `admin_edit_translation/3` | `(translation, title, content)` → manually_edited=true |
| `retranslate/1` | Admin-triggered: resets to pending, clears manually_edited |
| `batch_pending_translations/1` | `(supported_locales)` → list of `{blog_id, locale}` needing jobs |

---

## Oban Job Schema (implicit, via Oban)

Oban uses the `oban_jobs` table (created by Oban migration). The relevant job args:

```elixir
# BlogTranslationWorker job args (string keys — JSON serialized)
%{
  "blog_id" => integer,
  "locale"  => string  # e.g. "fr"
}
```

Unique constraint: `unique: [period: :infinity, keys: [:blog_id, :locale], states: [:available, :scheduled, :executing]]` — prevents duplicate queuing of the same post+locale combination while a job is pending or running.

---

## Config Schema Addition (`gsmlg_config`)

New `[i18n]` section in `GSMLG.Config.Schema`:

```elixir
@i18n_schema [
  supported_locales: [
    type: {:list, :string},
    required: true,
    doc: "BCP 47 locale codes for enabled languages"
  ],
  default_locale: [
    type: :string,
    required: true,
    doc: "Fallback locale when none can be resolved"
  ]
]
```

Default TOML (`gsmlg.toml`):

```toml
[i18n]
supported_locales = ["zh-Hans", "en", "zh-Hant", "fr", "es", "de", "it", "ja"]
default_locale = "zh-Hans"
```

---

## Implementation Status (verified 2026-03-20)

All schema changes, migrations, and context functions are **already implemented** in the codebase. The data model as documented above is live. No schema work remains.

| Component | Status |
|-----------|--------|
| `blogs.source_locale` migration | ✅ Applied (`20260320000002`) |
| `blog_translations` table + indexes | ✅ Applied (`20260320000003`) |
| `GSMLG.Content.Blog` schema update | ✅ Done |
| `GSMLG.Content.BlogTranslation` schema | ✅ Done (all 6 changesets) |
| All context functions listed above | ✅ Done |
| Oban job schema | ✅ Done (via Oban migration) |
| Config schema (`[i18n]`) | ✅ Done |
