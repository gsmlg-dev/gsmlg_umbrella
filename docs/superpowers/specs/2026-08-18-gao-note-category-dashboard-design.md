# GaoNote Category Dashboard Design

## Goal

Add a GaoNote dashboard at `/gao_notes` where administrators can browse configured
label categories and open the existing Notes page with an exact label-value filter.
Category configuration belongs on the existing `/gao_notes/label_settings` page.

This design adapts the category-dashboard behavior to GaoNote's current architecture:
PostgreSQL through Ecto for persistence and aggregation, and Phoenix LiveView for the
management UI. It does not introduce a REST dashboard API, OpenAPI schema, Turso
backend, or dashboard cache.

## Persistence Model

Add a `gao_note_category_settings` table with a generated ID, a required
`label_setting_id`, an optional string `value`, and a required integer `position`.

A null value represents a key-wide category such as `project`. A non-null value
represents an exact selector category such as `type=skill`. Positions define the
configured category order.

This representation keeps every category attached to an existing label setting while
allowing the same key to appear in multiple distinct selectors:

- Renaming a label setting preserves all of its category selectors.
- A category cannot reference a missing label setting.
- `type=skill` and `type=agent` can coexist.
- An identical selector cannot occur more than once.
- Existing installations default to no configured categories because the new table is
  initially empty.

The migration adds a unique index on position and selector uniqueness constraints for
both key-wide and exact-value entries. Its foreign key restricts deletion of referenced
label settings as a database backstop to the domain validation.

## Domain Operations

The `GSMLG.GaoNote` context exposes two category operations.

### Save category labels

The save operation accepts an ordered list of selectors containing a label-setting ID
and an optional exact value. The label key is always selected from the existing
catalog; it is never accepted as arbitrary text. The operation validates that:

- Every entry contains a valid label-setting ID.
- Every referenced label setting exists.
- Every supplied value is normalized and valid for the label setting's configured
  value type.
- No normalized `label_setting_id` and value selector occurs more than once.

Validation happens before persistence. A transaction then clears existing category
records and inserts the normalized selectors at consecutive positions.
Invalid input returns an error and leaves the existing configuration unchanged.

The operation returns the configured category selectors in their saved order.

### List category groups

The aggregation operation executes in PostgreSQL rather than loading notes into the
LiveView. It joins configured selectors and label settings to labels and active notes,
groups by category selector and stored label value, and counts matching notes. A note
is active when `deleted_at IS NULL`.

The operation returns every configured category, including categories with no values.
Categories are ordered by `position`. For a key-wide selector, values are ordered by
descending count and then ascending displayed value for stable ties. For an exact
selector, only the configured value can be returned. Stored string values are returned
unchanged, including the string representation of typed label values.

An exact selector with no matching active notes returns an empty values list, causing
the dashboard to render its normal empty-category presentation.

Key-only labels whose stored value is null or the empty string are excluded. They do
not provide a display value for the exact `key=value` filter required by category
chips.

Any aggregation error fails the whole operation. The caller does not receive partial
groups or counts.

## Label Deletion Protection

`GSMLG.GaoNote.delete_label_setting/2` rejects a label setting referenced by any
category selector. The returned domain error tells the caller to remove every category
using the label from Category labels before deleting it.

The Label Settings LiveView renders configured label deletion controls as disabled and
includes the same instruction. The domain check remains authoritative for callers
outside the LiveView and for concurrent requests.

## Label Settings UI

The existing `/gao_notes/label_settings` page gains a Category labels card above its
label table.

The card contains:

- A select control populated from existing label settings.
- An optional exact-value field validated against the selected label's value type.
- An Add action that appends the normalized selector to the local ordered selection.
- One removable chip for each selected selector, rendered in selection order.
- A Save action that persists the complete ordered selection.

Arbitrary label keys cannot be entered. Leaving the value blank adds a key-wide
selector such as `project`; supplying a value adds an exact selector such as
`type=skill`. The same normalized selector cannot be selected twice, while different
values for the same key are allowed. Removing and re-adding a selector moves it to the
end, providing a simple ordering mechanism without drag-and-drop JavaScript.

Failed validation or persistence leaves the stored configuration unchanged and shows
a clear error flash. A successful save refreshes the label catalog and displays a
confirmation flash.

## GaoNote Dashboard UI

Add an authenticated LiveView at `/gao_notes` and a Dashboard item as the first entry
in the GaoNote navigation group.

The dashboard loads category groups asynchronously. It renders one panel per selector
in configuration order. Each panel shows:

- The current key for a key-wide selector, or `key=value` for an exact selector, as its
  heading.
- Its description as supporting text when the description is non-empty.
- A clickable chip for every aggregated value.
- `No notes in this category.` when the category has no values.

Each value chip displays `value · count`. Its accessible label includes the category
key, value, and active-note count. A key-wide panel may contain many values; an exact
panel contains at most its configured value.

When no categories are configured, the page shows a compact link to
`/gao_notes/label_settings` inviting the administrator to configure Category labels.
The new page does not add unrelated label-summary or recent-update panels.

Loading and failure states follow the existing GaoNote LiveView pattern. A database
failure renders the non-destructive unavailable state and no category counts.

## Notes Filter Navigation

Category chips navigate to `/gao_notes/notes` at its existing default result limit with
one exact equality filter. The query uses the established plural filter contract:

```text
labels[]=key=value
```

The URL is generated through a shared GaoNote Notes path helper extracted from the
current Notes LiveView serializer. Phoenix query encoding handles spaces and special
characters in both key and value, producing a shareable URL. The Notes page continues
to own filter parsing and query behavior; label-selector semantics are unchanged.

## Error Handling and Consistency

- Invalid, duplicate, or unknown category selectors are rejected before persistence.
- A failed save does not partially reorder categories.
- Deleting a configured label is rejected with removal instructions.
- Dashboard aggregation failure produces the existing unavailable state rather than
  partial counts.
- Note, label-value, label-description, and category-order changes become visible on
  the next LiveView load. No cache or invalidation layer is introduced.

## Testing and Verification

Focused domain tests cover:

- Existing installations default to no category selectors.
- Valid ordered key-wide and exact selectors persist and can be replaced or cleared.
- Multiple exact values for the same key are accepted.
- Duplicate, malformed, mistyped, and unknown selectors are rejected atomically.
- Configured label settings cannot be deleted.
- Aggregation selects only configured key-wide or exact selectors and includes empty
  categories.
- Counts include only active notes and distinct stored values.
- Values use stored typed-label strings and have stable count/value ordering.

Focused admin LiveView tests cover:

- The `/gao_notes` route and navigation item.
- Key-wide and exact selector entry, removal, no-duplicate behavior, saving, and
  retained order.
- Disabled deletion with removal instructions for configured labels.
- Dashboard category ordering and description display.
- Empty configuration and empty-category presentation.
- Value/count chip labels and correctly escaped exact-filter destinations.
- Asynchronous loading and unavailable presentation.

Verification runs only GaoNote domain tests, GaoNote admin LiveView/menu tests,
formatting for modified files, compilation with warnings treated as errors where
practical, and `git diff --check`.

## Out of Scope

- REST or JSON dashboard endpoints.
- OpenAPI schemas or frontend DTOs.
- Turso or any storage backend other than the existing Ecto repository.
- A dashboard cache or invalidation subsystem.
- New Notes pagination or changes to label-selector semantics.
- General label-summary and recent-update dashboard panels.
- MCP tool changes or note mutation behavior changes.
