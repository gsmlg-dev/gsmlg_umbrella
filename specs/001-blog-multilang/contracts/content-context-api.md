# Contract: GSMLG.Content — Translation Functions

**Module**: `GSMLG.Content` (`apps/gsmlg/lib/gsmlg/content.ex`)

Additions to the existing Content context for managing blog translations.

---

## New Functions

### `create_blog/1` — Modified

Wraps existing insert in `Ecto.Multi` to atomically create pending translation records and enqueue Oban jobs for all non-source locales.

```elixir
@spec create_blog(map()) :: {:ok, Blog.t()} | {:error, Ecto.Changeset.t()}
```

**Side effects**: Creates `blog_translations` records (status: `"pending"`) and queues `BlogTranslationWorker` jobs for each configured locale that is not the post's `source_locale`.

---

### `update_blog/2` — Modified

Wraps existing update in `Ecto.Multi`. After saving:
- Marks all non-`manually_edited` translations as `"outdated"`.
- Queues new `BlogTranslationWorker` jobs for outdated translations.
- Skips translations where `manually_edited = true`.

```elixir
@spec update_blog(Blog.t(), map()) :: {:ok, Blog.t()} | {:error, Ecto.Changeset.t()}
```

---

### `get_translation/2`

```elixir
@spec get_translation(blog_id :: integer(), locale :: String.t()) ::
  BlogTranslation.t() | nil
```

Returns the translation for a blog+locale pair, or `nil` if none exists.

---

### `get_translation!/2`

```elixir
@spec get_translation!(blog_id :: integer(), locale :: String.t()) ::
  BlogTranslation.t()
```

Raises `Ecto.NoResultsError` if not found.

---

### `list_translations/1`

```elixir
@spec list_translations(blog_id :: integer()) :: [BlogTranslation.t()]
```

Returns all translation records for a blog (any status). Used by admin dashboard.

---

### `create_pending_translations/2`

```elixir
@spec create_pending_translations(Blog.t(), [String.t()]) ::
  {:ok, [BlogTranslation.t()]} | {:error, term()}
```

Creates `BlogTranslation` records with `status: "pending"` for each locale in the list (excluding the blog's `source_locale`). Called inside `Ecto.Multi` by `create_blog/1`.

---

### `mark_translation_in_progress/1`

```elixir
@spec mark_translation_in_progress(BlogTranslation.t()) ::
  {:ok, BlogTranslation.t()} | {:error, Ecto.Changeset.t()}
```

Updates status to `"in_progress"`. Called by the Oban worker when it starts processing.

---

### `complete_translation/3`

```elixir
@spec complete_translation(BlogTranslation.t(), String.t(), String.t()) ::
  {:ok, BlogTranslation.t()} | {:error, Ecto.Changeset.t()}
```

Sets `title`, `content`, and `status: "completed"`. Called by worker on AI translation success.

**Note**: Does NOT set `manually_edited`. A `complete_translation` call always represents AI output.

---

### `mark_translation_failed/1`

```elixir
@spec mark_translation_failed(BlogTranslation.t()) ::
  {:ok, BlogTranslation.t()} | {:error, Ecto.Changeset.t()}
```

Sets `status: "failed"`. Called by the Oban worker on the last failed attempt (`job.attempt >= job.max_attempts`).

---

### `admin_edit_translation/3`

```elixir
@spec admin_edit_translation(BlogTranslation.t(), String.t(), String.t()) ::
  {:ok, BlogTranslation.t()} | {:error, Ecto.Changeset.t()}
```

Sets `title`, `content`, `status: "completed"`, and `manually_edited: true`. Protected from automated overwrite.

---

### `retranslate/1`

```elixir
@spec retranslate(BlogTranslation.t()) ::
  {:ok, BlogTranslation.t()} | {:error, term()}
```

Admin-triggered re-translation. Resets `status: "pending"`, `manually_edited: false`, clears title/content, and inserts a new `BlogTranslationWorker` Oban job. Bypasses the `manually_edited` guard.

---

### `batch_pending_translations/1`

```elixir
@spec batch_pending_translations([String.t()]) :: [{integer(), String.t()}]
```

Returns a list of `{blog_id, locale}` tuples that need translation. Covers:
- Existing records with `status in ["pending", "failed", "outdated"]`
- Blog+locale combinations where no translation record exists yet (for newly added locales)

Used by the batch mix task or admin-triggered batch operation.
