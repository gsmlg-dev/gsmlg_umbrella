# Contract: GSMLG.Workers.BlogTranslationWorker

**Module**: `GSMLG.Workers.BlogTranslationWorker`
**Path**: `apps/gsmlg/lib/gsmlg/workers/blog_translation_worker.ex`

---

## Configuration

```elixir
use Oban.Worker,
  queue: :translations,
  max_attempts: 3,
  unique: [
    period: :infinity,
    keys: [:blog_id, :locale],
    states: [:available, :scheduled, :executing]
  ]
```

**Queue**: `:translations` with `concurrency: 5` (configured in `GSMLG.Application`).

**Unique constraint**: Prevents duplicate jobs for the same `blog_id` + `locale` pair while a job is pending, scheduled, or executing. Completed/discarded jobs do not block new ones.

---

## Job Args

```elixir
# String keys (JSON serialization — Oban Thinking rule)
%{
  "blog_id" => integer(),
  "locale"  => String.t()   # BCP 47, e.g. "fr", "zh-Hans"
}
```

---

## `perform/1` Contract

```elixir
@impl Oban.Worker
@spec perform(Oban.Job.t()) ::
  {:ok, term()}
  | {:error, term()}      # retry
  | {:cancel, term()}     # permanent skip (no retry)
```

**Steps**:
1. Fetch `Blog` by `blog_id` — if not found, return `{:cancel, "blog not found"}`.
2. Fetch or create `BlogTranslation` record for `{blog_id, locale}`.
3. Call `Content.mark_translation_in_progress/1`.
4. Call `Translation.Provider.translate(blog.title, blog.content, blog.source_locale, locale)`.
5. On `{:ok, %{title: t, content: c}}` → call `Content.complete_translation/3` → return `{:ok, :translated}`.
6. On `{:error, :rate_limited}` → return `{:snooze, 60}` (retry after 60 seconds).
7. On `{:error, reason}`:
   - If `job.attempt >= job.max_attempts` → call `Content.mark_translation_failed/1`.
   - Return `{:error, reason}` (Oban handles retry backoff).

**Side effect on success**: Broadcast via `Phoenix.PubSub` to `"blog_translations:#{blog_id}"` topic so admin LiveView updates in real time.

---

## Enqueueing

**On post create** (inside `Ecto.Multi`):
```elixir
BlogTranslationWorker.new(%{blog_id: blog.id, locale: locale})
```

**Batch enqueue** (for backfill or new locale):
```elixir
{blog_id, locale}
|> then(fn {id, loc} -> BlogTranslationWorker.new(%{blog_id: id, locale: loc}) end)
|> Oban.insert()
```

---

## Error Semantics

| Return value | Meaning |
|--------------|---------|
| `{:ok, _}` | Translation complete — Oban marks job as completed |
| `{:error, reason}` | Transient failure — Oban retries with backoff |
| `{:cancel, reason}` | Permanent skip — Oban discards without retry (blog deleted, etc.) |
| `{:snooze, seconds}` | Rate limited — retry after delay |
