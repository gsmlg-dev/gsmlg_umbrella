# Blog Multi-Language Refactor — Design Document (v3)

## Overview

Refactor the blog system to support multi-language via AI translation. Each post has a **source locale** identifying its original language. Translations are AI-generated derivatives stored alongside the source. Locale resolution via `Accept-Language` header with UI toggle.

Supported locales are **configuration-driven** — initially `en` + `zh`, extensible to `ja`, `ko`, `es`, etc. by adding a config entry. No schema changes or code changes needed to add a language.

---

## Current Schema

```
blogs(id, slug, title, date, author, content, inserted_at, updated_at)
```

Mixed-language content: some posts written in Chinese, some in English. No locale metadata.

---

## Target Schema

```
┌──────────────────────────────────┐       ┌─────────────────────────────────────┐
│            blogs                 │       │       blog_translations             │
├──────────────────────────────────┤       ├─────────────────────────────────────┤
│ id            : bigserial        │──┐    │ id           : bigserial            │
│ slug          : varchar (unique) │  │    │ blog_id      : bigint (FK)          │
│ title         : varchar          │  └───>│ locale       : varchar(10)          │
│ date          : date             │       │ title        : text                 │
│ author        : varchar          │       │ content      : text                 │
│ content       : text             │       │ status       : varchar(20)          │
│ source_locale : varchar(10)      │       │ inserted_at  : timestamp            │
│ inserted_at   : timestamp        │       │ updated_at   : timestamp            │
│ updated_at    : timestamp        │       └─────────────────────────────────────┘
└──────────────────────────────────┘        UNIQUE(blog_id, locale)
```

### Key Decisions

- **blogs table stays as source of truth** — title + content remain the original human-written text
- **source_locale** on blogs — declares the language of the source content
- **blog_translations** — AI-generated translations only, never duplicates the source locale
- **status** on translations — tracks translation lifecycle: `"pending"` | `"translating"` | `"completed"` | `"failed"` | `"stale"`
- **stale detection** — when source content updates, mark all translations as `"stale"` for re-translation
- **locale list is config, not code** — no hardcoded locale lists in schemas or validations

---

## Locale Configuration

Locales are defined in application config, not in schema validations or DB enums:

```elixir
# config/config.exs
config :gsmlg, :blog,
  supported_locales: ~w(en zh-Hans zh-Hant fr es de it ja),
  default_locale: "en"
```

Accessed via a module:

```elixir
defmodule GSMLG.Blog.Locale do
  @locale_names %{
    "en"      => "English",
    "zh-Hans" => "简体中文",
    "zh-Hant" => "繁體中文",
    "fr"      => "Français",
    "es"      => "Español",
    "de"      => "Deutsch",
    "it"      => "Italiano",
    "ja"      => "日本語"
  }

  def supported, do: Application.fetch_env!(:gsmlg, :blog) |> Keyword.fetch!(:supported_locales)
  def default, do: Application.fetch_env!(:gsmlg, :blog) |> Keyword.get(:default_locale, "en")
  def supported?(locale), do: locale in supported()
  def target_locales(source_locale), do: supported() -- [source_locale]
  def display_name(locale), do: Map.get(@locale_names, locale, locale)
  def all_with_names, do: Enum.map(supported(), &{&1, display_name(&1)})
end
```

Uses BCP 47 tags: `zh-Hans` (Simplified Chinese) and `zh-Hant` (Traditional Chinese) rather than ad-hoc codes. The `locale` column is `varchar(10)` which fits all BCP 47 primary subtags.

### Adding a New Language

To add Korean support later:

1. Add `"ko" => "한국어"` to `@locale_names` and `"ko"` to config
2. Run batch translation task → enqueues Oban jobs for `"ko"` across all posts
3. Done. No migrations, no code changes.

The `locale` column is a free-form `varchar(10)` — no DB enum, no check constraint on specific values. Validation happens at the application layer via `Locale.supported?/1`.

### Accept-Language Matching

`zh-Hans` / `zh-Hant` require special matching against browser `Accept-Language` headers. Browsers typically send `zh-CN` (Simplified) or `zh-TW` (Traditional). The SetLocale plug maps:

```
zh-CN, zh-SG, zh        → zh-Hans
zh-TW, zh-HK, zh-Hant   → zh-Hant
```

### Translation vs Source

```
Blog(source_locale: "zh-Hans", title: "构建分布式系统", content: "...")
  ├─ BlogTranslation(locale: "en",      title: "Building Distributed Systems", status: "completed")
  ├─ BlogTranslation(locale: "zh-Hant", title: "構建分布式系統",               status: "completed")
  ├─ BlogTranslation(locale: "ja",      title: "分散システムの構築",            status: "completed")
  └─ BlogTranslation(locale: "fr",      title: "Construire des systèmes...",  status: "pending")

Blog(source_locale: "en", title: "Web Terminals in Elixir", content: "...")
  ├─ BlogTranslation(locale: "zh-Hans", title: "Elixir 中的 Web 终端",        status: "completed")
  ├─ BlogTranslation(locale: "zh-Hant", title: "Elixir 中的 Web 終端",        status: "completed")
  └─ ...7 target locales total
```

A translation row where `locale == blog.source_locale` should never exist.

---

## Migration Strategy

Single migration — additive only:

```sql
-- Add source_locale to existing blogs table
ALTER TABLE blogs ADD COLUMN source_locale varchar(10) NOT NULL DEFAULT 'en';

-- Create translations table
CREATE TABLE blog_translations (
  id bigserial PRIMARY KEY,
  blog_id bigint NOT NULL REFERENCES blogs(id) ON DELETE CASCADE,
  locale varchar(10) NOT NULL,
  title text NOT NULL,
  content text NOT NULL,
  status varchar(20) NOT NULL DEFAULT 'pending',
  inserted_at timestamp NOT NULL,
  updated_at timestamp NOT NULL
);

CREATE UNIQUE INDEX blog_translations_blog_id_locale_index ON blog_translations(blog_id, locale);
CREATE INDEX blog_translations_status_index ON blog_translations(status);
```

### Post-Migration: Classify Source Locales

After migration, run a one-time task to detect and set `source_locale` for existing posts.
Options:
1. **Manual** — you tag each post
2. **Heuristic** — detect CJK characters in title/content → `"zh"`, otherwise `"en"`
3. **AI-assisted** — use LLM to classify, then confirm

Heuristic approach (good enough for initial classification — existing posts are Simplified Chinese or English):

```elixir
# Simplified Chinese uses CJK unified ideographs; existing content is all zh-Hans
def detect_locale(text) do
  if String.match?(text, ~r/[\x{4e00}-\x{9fff}]/u), do: "zh-Hans", else: "en"
end
```

---

## Read Path — Locale Resolution

Priority chain:

```
1. ?lang=zh query param      → explicit override, set cookie
2. Cookie "locale"            → persisted preference
3. Accept-Language header     → browser preference
4. Default "en"               → fallback
```

### Serving Content by Locale

```
requested_locale = conn.assigns.locale

if blog.source_locale == requested_locale do
  # Serve source directly from blogs table
  {blog.title, blog.content}
else
  # Look for translation
  case get_translation(blog, requested_locale) do
    %{status: "completed"} = t -> {t.title, t.content}
    _                           -> {blog.title, blog.content}  # fallback to source
  end
end
```

Fallback is always the source content — never a 404 for missing translations.

### Context Functions

```
list_blogs(locale)
  → load all published blogs
  → preload translations for requested locale
  → for each blog, resolve display title/content

get_blog_by_slug!(slug, locale)
  → load blog + translation for locale
  → resolve display content with fallback

translation_status(blog)
  → returns %{en: :source, zh: :completed} or similar map
```

---

## Write Path — AI Translation

### Translation Lifecycle

```
  source updated
       │
       ▼
   ┌─────────┐    trigger     ┌──────────────┐    success    ┌───────────┐
   │ pending  │──────────────>│ translating   │─────────────>│ completed │
   └─────────┘                └──────────────┘               └───────────┘
       ▲                           │                              │
       │                           │ failure                      │ source updated
       │                           ▼                              │
       │                      ┌──────────┐                   ┌────────┐
       └──────────────────────│ failed   │                   │ stale  │
            retry             └──────────┘                   └────────┘
                                                                  │
                                                                  │ re-translate
                                                                  ▼
                                                            ┌──────────────┐
                                                            │ translating  │
                                                            └──────────────┘
```

### Translation Trigger Points

1. **On blog create** — enqueue translation job for all target locales
2. **On blog update** (title or content changed) — mark existing translations as `"stale"`, enqueue re-translation
3. **Manual trigger** — admin UI button to force re-translate
4. **Batch job** — translate all `"pending"` or `"stale"` translations

### Oban Worker

```
TranslateBlogWorker
  args: %{blog_id, target_locale}
  
  perform:
    1. Load blog source content
    2. Set translation status → "translating"
    3. Call AI translation API (Anthropic / OpenAI / etc.)
    4. Upsert translation with result, status → "completed"
    5. On failure → status "failed", schedule retry
```

### Stale Detection on Update

```
def update_blog(blog, attrs) do
  Multi.new()
  |> Multi.update(:blog, Blog.changeset(blog, attrs))
  |> Multi.run(:mark_stale, fn _repo, %{blog: updated} ->
    if content_changed?(blog, updated) do
      mark_translations_stale(updated.id)
    else
      {:ok, :no_change}
    end
  end)
  |> Multi.run(:enqueue_translations, fn _repo, %{blog: updated, mark_stale: result} ->
    if result != :no_change do
      enqueue_translations(updated)
    else
      {:ok, :skipped}
    end
  end)
  |> Repo.transaction()
end
```

---

## Routing

No URL changes. Routes stay as:

```
/blog              → index
/blog/:slug        → show
```

Locale resolved from conn, not URL. Same URL serves correct language per viewer.

### Template Data

Each blog in the list/show view gets:

```
%{
  blog: %Blog{},
  display_title: "resolved title",
  display_content: "resolved content",
  display_locale: "en" | "zh-Hans" | "ja" | ...,
  is_translated: boolean,
  available_locales: [%{locale: "en", status: :source}, %{locale: "zh", status: :completed}]
}
```

`is_translated` lets the UI show a subtle indicator (e.g., "AI translated" badge).

---

## Admin Concerns

- **Translation dashboard** — list posts with translation status per locale
- **Force re-translate** — button per post or bulk action
- **Edit translation** — allow manual correction of AI output (changes status to `"completed"`, won't be overwritten unless explicitly re-triggered)
- **Source locale override** — ability to change `source_locale` if misclassified

---

## Claude Code Implementation Prompts

### Prompt 1: Locale Config + Migration + Schemas

```
Project: gsmlg_umbrella

Add multi-language support to the existing blogs system.
Supported locales are CONFIG-DRIVEN, not hardcoded.

1. Locale configuration module (GSMLG.Blog.Locale):
   - Reads from Application config: :gsmlg, :blog, :supported_locales and :default_locale
   - Functions:
     - supported() :: [String.t()]      — list of supported locale codes
     - default() :: String.t()          — fallback locale
     - supported?(locale) :: boolean    — validation check
     - target_locales(source_locale)    — supported() -- [source_locale]
     - display_name(locale)             — human-readable name from @locale_names map
     - all_with_names()                 — [{locale, name}] for UI dropdowns
   - @locale_names map:
     "en" => "English", "zh-Hans" => "简体中文", "zh-Hant" => "繁體中文",
     "fr" => "Français", "es" => "Español", "de" => "Deutsch",
     "it" => "Italiano", "ja" => "日本語"
   - Config in config.exs:
     config :gsmlg, :blog,
       supported_locales: ~w(en zh-Hans zh-Hant fr es de it ja),
       default_locale: "en"

2. Ecto Migration:
   - Add `source_locale` column (varchar(10), NOT NULL, default "en") to `blogs` table
   - Create `blog_translations` table:
     - id (bigserial)
     - blog_id (bigint, FK to blogs ON DELETE CASCADE)
     - locale (varchar(10), NOT NULL)
     - title (text, NOT NULL)  
     - content (text, NOT NULL)
     - status (varchar(20), NOT NULL, default "pending")
       Valid values: "pending", "translating", "completed", "failed", "stale"
     - inserted_at, updated_at (timestamps)
   - Unique index on (blog_id, locale)
   - Index on status (for batch queries)
   - NO database-level enum or check constraint on locale — kept as free varchar
     so adding languages never requires a migration

3. Update Blog schema:
   - Add :source_locale field (default "en")
   - Add has_many :translations, BlogTranslation
   - Validate source_locale with: validate_change(:source_locale, &Locale.supported?/1)
     i.e. validate against runtime config, NOT a hardcoded list

4. Create BlogTranslation schema:
   - belongs_to :blog
   - Fields: locale, title, content, status
   - Validate locale against Locale.supported?/1 (runtime, not hardcoded)
   - Validate status in ~w(pending translating completed failed stale)
   - unique_constraint [:blog_id, :locale]

5. Mix task (mix blog.classify_locales) to set source_locale for existing posts:
   - Detect CJK characters (Unicode range 4e00-9fff) → "zh-Hans", else "en"
   - All existing Chinese content is Simplified Chinese
   - Print summary before updating
   - Accept --dry-run flag
   - Accept --confirm flag to execute
```

### Prompt 2: Context Functions + Locale Plug

```
Project: gsmlg_umbrella
Depends on: Prompt 1

All locale lists MUST come from GSMLG.Blog.Locale module, never hardcoded.

1. Blog context functions for multi-language reads:
   - list_blogs(locale) — all blogs, resolve display content per locale
     If locale matches source_locale → use blog.title/content directly
     Else → use completed translation, fallback to source
   - get_blog_by_slug!(slug, locale) — single blog with resolved content
   - available_locales(blog) — map of locale => status (:source | translation status)
     Iterates Locale.supported(), checks which have translations
   
2. Blog context functions for translation management:
   - create_translation(blog, locale, attrs) — insert translation row
   - update_translation(translation, attrs)
   - mark_translations_stale(blog_id) — set all translations to "stale"
   - list_pending_translations() — all with status in ["pending", "stale"]
   - missing_translations(blog) — Locale.target_locales(blog.source_locale)
     minus locales that already have a "completed" translation

3. Update blog create/update functions:
   - On create: enqueue translation jobs via Locale.target_locales(source_locale)
   - On update (if title or content changed): mark translations stale + enqueue

4. SetLocale plug:
   - Resolution: params["lang"] > session cookie > Accept-Language > Locale.default()
   - Parse Accept-Language q-values, match against Locale.supported()
   - Chinese variant mapping: zh-CN/zh-SG/zh → zh-Hans, zh-TW/zh-HK → zh-Hant
   - Store in conn.assigns.locale and session
   - Add to browser pipeline in router

5. Update blog controller/live views:
   - Use conn.assigns.locale in all blog queries
   - Pass available_locales + Locale.all_with_names() to templates for language switcher
   - Language switcher shows native names (简体中文, 繁體中文, 日本語, etc.)
   - Show "AI translated" indicator when serving translation
```

### Prompt 3: Translation Worker (Oban)

```
Project: gsmlg_umbrella  
Depends on: Prompts 1-2

Create an Oban worker for AI blog translation.
Use GSMLG.Blog.Locale for all locale lists.

1. TranslateBlogWorker:
   - Queue: :translations, max_attempts: 3
   - Args: %{"blog_id" => id, "target_locale" => locale}
   - perform/1:
     a. Load blog, verify target_locale != source_locale
     b. Verify Locale.supported?(target_locale) — reject if locale was removed from config
     c. Set existing translation status to "translating" (or create with "translating")
     d. Build translation prompt using Locale.display_name/1 for natural language names:
        - System: "You are a professional translator. Translate the following blog post
          from {display_name(source_locale)} to {display_name(target_locale)}.
          Preserve all markdown formatting.
          Return JSON: {\"title\": \"...\", \"content\": \"...\"}"
        - For zh-Hans ↔ zh-Hant: prompt should specify "Simplified Chinese" vs
          "Traditional Chinese" explicitly to avoid ambiguity
     e. Call AI API (make the API module configurable/injectable for testing)
     f. Parse response, upsert translation with status "completed"
     g. On API error: set status "failed", let Oban retry

2. Helper to enqueue translations:
   - enqueue_translations(blog) — creates a job per Locale.target_locales(blog.source_locale)

3. Batch task (Mix task or Oban cron):
   - For each blog, compute Locale.target_locales(blog.source_locale)
   - Find missing or stale translations for each pair
   - Enqueue jobs
   - This naturally picks up newly added locales — if "ko" is added to config,
     next batch run enqueues "ko" translations for all existing posts

4. Make the AI client a behaviour so it's mockable in tests:
   - Behaviour: translate(content, from_locale, to_locale) :: {:ok, map} | {:error, term}
   - Default impl calls Anthropic API
   - Test impl returns deterministic translations
```

---

## Testing Strategy

1. **Migration** — verify source_locale classification: CJK content → `"zh-Hans"`, otherwise `"en"`
2. **Read path** — source locale served directly, translation served when available, fallback to source when missing
3. **Stale detection** — update blog content → all 7 translations marked stale
4. **Translation worker** — mock AI client, verify status transitions
5. **Locale plug** — Accept-Language parsing with zh-CN → zh-Hans mapping, cookie persistence, param override
6. **Constraint enforcement** — no duplicate (blog_id, locale), no translation where locale == source_locale
7. **Adding a locale** — add `"ko"` to config, run batch task, verify jobs enqueued for all existing posts
8. **Removing a locale** — worker rejects jobs for unsupported locale, existing translations kept but not served
9. **zh-Hans ↔ zh-Hant** — verify these are treated as distinct languages, not fallbacks of each other
