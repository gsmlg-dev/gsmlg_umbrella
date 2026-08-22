# GaoNote Category Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an ordered, persisted GaoNote category-selector configuration and a `/gao_notes` dashboard that links active-note counts to the existing exact Notes filter.

**Architecture:** Persist category selectors in a relational table keyed to existing label settings, with an optional exact value and explicit position. Keep selector validation and PostgreSQL aggregation in `GSMLG.GaoNote`; keep routes, URL generation, asynchronous presentation, and configuration interactions in `gsmlg_admin_web`. Key-wide selectors aggregate every non-blank stored value, while exact selectors aggregate only their configured value.

**Tech Stack:** Elixir 1.18, Ecto/PostgreSQL, Phoenix LiveView, Phoenix Verified Routes, phoenix_duskmoon, ExUnit, Floki

---

## File Map

- Create `apps/gsmlg/priv/repo/migrations/20260818000000_create_gao_note_category_settings.exs`: relational selector persistence and uniqueness constraints.
- Create `apps/gsmlg_gao_note/lib/gsmlg/gao_note/category_setting.ex`: Ecto schema for ordered key-wide/exact selectors.
- Modify `apps/gsmlg_gao_note/lib/gsmlg/gao_note/label_setting.ex`: category association and virtual configured-category count.
- Modify `apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex`: selector validation/replacement, deletion protection, and active-note aggregation.
- Create `apps/gsmlg_gao_note/test/gsmlg/gao_note/category_settings_test.exs`: focused domain persistence, validation, deletion, and aggregation regressions.
- Create `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/notes_path.ex`: shared exact Notes-filter URL serializer.
- Create `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/dashboard_live.ex`: asynchronous category dashboard.
- Modify `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/index.ex`: use the shared Notes path serializer.
- Modify `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/label_setting_live/index.ex`: ordered selector add/remove/save UI and delete protection.
- Modify `apps/gsmlg_admin_web/lib/gsmlg/admin_web/router.ex`: authenticated `/gao_notes` route.
- Modify `apps/gsmlg_admin_web/lib/gsmlg/admin_web/admin_menu.ex`: GaoNote Dashboard navigation entry.
- Modify `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_label_live_test.exs`: selector configuration UI regressions.
- Create `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_dashboard_live_test.exs`: dashboard ordering, empty states, counts, and URL encoding.
- Modify `apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs`: route and active-menu coverage.
- Modify `apps/gsmlg_admin_web/test/gsmlg/admin_web/components/admin_navigation_test.exs`: rendered navigation coverage.
- Add `docs/superpowers/specs/2026-08-18-gao-note-category-dashboard-design.md` and this plan to the scoped commit.

### Task 1: Persist ordered category selectors

**Files:**
- Create: `apps/gsmlg/priv/repo/migrations/20260818000000_create_gao_note_category_settings.exs`
- Create: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/category_setting.ex`
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/label_setting.ex`
- Test: `apps/gsmlg_gao_note/test/gsmlg/gao_note/category_settings_test.exs`

- [ ] **Step 1: Write the failing persistence tests**

Add a `describe "category settings"` block proving an empty default, ordered schema fields, multiple exact values for one key, and duplicate-selector constraints. Use real `LabelSetting` records and repository inserts rather than mocks.

```elixir
test "category settings default to an empty ordered list" do
  assert GaoNote.list_category_groups() == []
end

test "stores key-wide and multiple exact selectors for one label key" do
  {:ok, project} = GaoNote.create_label_setting(%{name: "project"})
  {:ok, type} = GaoNote.create_label_setting(%{name: "type"})

  assert {:ok, categories} =
           GaoNote.save_category_settings([
             %{label_setting_id: project.id},
             %{label_setting_id: type.id, value: "skill"},
             %{label_setting_id: type.id, value: "agent"}
           ])

  assert Enum.map(categories, &{&1.position, &1.label_setting.name, &1.value}) == [
           {0, "project", nil},
           {1, "type", "skill"},
           {2, "type", "agent"}
         ]
end
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
devenv shell -- env DATABASE_URL=postgres://gsmlg_dev:gsmlg_dev@localhost:5433/gsmlg_dev \
  mix test apps/gsmlg_gao_note/test/gsmlg/gao_note/category_settings_test.exs
```

Expected: failure because `CategorySetting`, `list_category_groups/0`, and `save_category_settings/1` do not exist.

- [ ] **Step 3: Add the migration and schemas**

Create a binary-ID table with timestamps, `label_setting_id` using `on_delete: :restrict`, nullable `value`, and non-negative `position`. Add:

```elixir
create unique_index(:gao_note_category_settings, [:position],
         name: :gao_note_category_settings_position_index
       )

create unique_index(:gao_note_category_settings, [:label_setting_id],
         where: "value IS NULL",
         name: :gao_note_category_settings_key_wide_index
       )

create unique_index(:gao_note_category_settings, [:label_setting_id, :value],
         where: "value IS NOT NULL",
         name: :gao_note_category_settings_exact_selector_index
       )

create index(:gao_note_category_settings, [:label_setting_id])

create constraint(:gao_note_category_settings, :category_position_non_negative,
         check: "position >= 0"
       )
```

Define `GSMLG.GaoNote.CategorySetting` with `belongs_to(:label_setting, LabelSetting)`, `field(:value, :string)`, and `field(:position, :integer)`. Its changeset casts those three fields, requires the foreign key and position, validates a non-negative position, and declares the named foreign-key/unique constraints. Add `has_many(:category_settings, CategorySetting)` and virtual `category_count` to `LabelSetting`.

- [ ] **Step 4: Implement minimal ordered persistence**

Add:

```elixir
defp list_category_settings do
  CategorySetting
  |> order_by([category], asc: category.position)
  |> preload(:label_setting)
  |> Repo.all()
end

def save_category_settings(selectors) when is_list(selectors) do
  with {:ok, normalized} <- normalize_category_selectors(selectors) do
    Repo.transaction(fn ->
      Repo.delete_all(CategorySetting)

      normalized
      |> Enum.with_index()
      |> Enum.each(fn {selector, position} ->
        %CategorySetting{}
        |> CategorySetting.changeset(Map.put(selector, :position, position))
        |> Repo.insert!()
      end)

      list_category_settings()
    end)
  end
end

def save_category_settings(_selectors), do: {:error, :category_settings_must_be_a_list}
```

`normalize_category_selectors/1` must cast UUIDs, load every referenced label setting in one query, trim optional values, map blank values to `nil`, reuse typed-label validation, and reject identical normalized `{label_setting_id, value}` pairs before the transaction.

- [ ] **Step 5: Run the focused tests and verify GREEN**

Run the command from Step 2. Expected: the new category persistence tests pass without changing existing label tests.

### Task 2: Validate selectors atomically and protect configured label keys

**Files:**
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex`
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/label_setting.ex`
- Modify: `apps/gsmlg_gao_note/test/gsmlg/gao_note/category_settings_test.exs`

- [ ] **Step 1: Write failing validation and deletion tests**

Cover malformed UUIDs, unknown label IDs, duplicate key-wide selectors, duplicate normalized exact selectors, invalid typed values such as `year=20x6`, atomic preservation of the old list after rejection, clearing with `[]`, and deletion protection.

```elixir
type_id = type.id

assert {:error, {:duplicate_category_selector, ^type_id, "skill"}} =
         GaoNote.save_category_settings([
           %{label_setting_id: type.id, value: " skill "},
           %{label_setting_id: type.id, value: "skill"}
         ])

assert {:error, {:category_label_in_use, "type"}} =
         GaoNote.delete_label_setting(type)
```

- [ ] **Step 2: Run the tests and verify RED**

Run the Task 1 test command. Expected: the new error contracts or atomicity assertions fail.

- [ ] **Step 3: Implement validation and deletion protection**

Return explicit errors:

```elixir
{:error, {:invalid_category_selector, index, :invalid_label_setting_id}}
{:error, {:unknown_category_label, label_setting_id}}
{:error, {:invalid_category_value, label_setting_id, errors}}
{:error, {:duplicate_category_selector, label_setting_id, value}}
{:error, {:category_label_in_use, label_setting.name}}
```

Extend `list_label_settings/1` with a left join to `CategorySetting` and `category_count: count(category.id, :distinct)` so the UI can render authoritative deletion state. In `delete_label_setting/2`, check category references before deleting; retain the restrictive foreign key for concurrent/direct deletion safety.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run the Task 1 command. Expected: all category validation/deletion tests and prior GaoNote tests pass.

### Task 3: Aggregate active-note category values in PostgreSQL

**Files:**
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex`
- Modify: `apps/gsmlg_gao_note/test/gsmlg/gao_note/category_settings_test.exs`

- [ ] **Step 1: Write failing aggregation tests**

Create configured and unconfigured label keys, active and trashed notes, tied counts, typed values, key-only blank values, exact selectors with matches, and exact selectors with zero matches. Assert this shape:

```elixir
assert [
         %{
           key: "project",
           selector: "project",
           configured_value: nil,
           description: "Project",
           values: [%{value: "yellow-dog", count: 2}, %{value: "sigma", count: 1}]
         },
         %{
           key: "type",
           selector: "type=skill",
           configured_value: "skill",
           values: [%{value: "skill", count: 1}]
         }
       ] = GaoNote.list_category_groups()
```

Also assert configuration order and count-desc/value-asc tie ordering.

- [ ] **Step 2: Run the focused tests and verify RED**

Run the Task 1 command. Expected: failure because `list_category_groups/0` is absent.

- [ ] **Step 3: Implement database aggregation**

Build an active-count subquery grouped by `{label_setting_id, value}` from `Label` joined to `Note`. Require `is_nil(note.deleted_at)`, reject label values in `[nil, ""]`, and select `count(note.id)`. Left-join that aggregate subquery to ordered `CategorySetting` rows using the selector predicate `is_nil(category.value) or category.value == count_row.value`. This preserves configured empty categories without leaking zero-count values from deleted-only notes. Merge only the small aggregate result rows into group maps in Elixir; do not load note records or count in the LiveView.

Return every configured selector even when it has no aggregate rows. Sort each values list with:

```elixir
Enum.sort_by(values, &{-&1.count, &1.value})
```

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run the Task 1 command. Expected: all aggregation and existing GaoNote tests pass.

### Task 4: Add shared Notes URL generation and the GaoNote dashboard

**Files:**
- Create: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/notes_path.ex`
- Create: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/dashboard_live.ex`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/index.ex`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/router.ex`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/admin_menu.ex`
- Create: `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_dashboard_live_test.exs`
- Modify: `apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs`
- Modify: `apps/gsmlg_admin_web/test/gsmlg/admin_web/components/admin_navigation_test.exs`

- [ ] **Step 1: Write failing route, navigation, dashboard, and URL tests**

Assert authentication, `/gao_notes` routing, first GaoNote menu position, empty configuration CTA, configured order, descriptions, exact empty state, chip text/accessible labels, and special-character encoding.

```elixir
assert has_element?(view, ~s(a[href="/gao_notes/notes?labels[]=project%3Dyellow-dog"]))
assert has_element?(view, ~s(a[aria-label="Filter notes by project=yellow-dog, 2 active notes"]))
```

Use URI/query decoding rather than depending on one incidental parameter-order representation when checking spaces, `&`, `+`, and `=`.

- [ ] **Step 2: Run focused admin tests and verify RED**

Run:

```bash
devenv shell -- env DATABASE_URL=postgres://gsmlg_dev:gsmlg_dev@localhost:5433/gsmlg_dev \
  mix test \
    apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_dashboard_live_test.exs \
    apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs \
    apps/gsmlg_admin_web/test/gsmlg/admin_web/components/admin_navigation_test.exs
```

Expected: missing route/module/menu tests fail.

- [ ] **Step 3: Implement the shared serializer and dashboard**

Use the recorded upstream Feature request `duskmoon-dev/phoenix-duskmoon-ui#141`, `[internal] Support navigable and removable chip semantics`, labeled `internal request` with severity `needed`. The installed `dm_chip` cannot act as a link and its plain delete event is not forwarded by the standard hook. Reference issue `#141` in a `WORKAROUND(upstream)` HEEx comment at the semantic link/button callsites.

`GSMLG.AdminWeb.GaoNoteLive.NotesPath` owns:

```elixir
def index(filters \\ %{}) do
  search = blank_to_nil(filters["search"] || filters[:search])
  labels = normalize_labels(filters["labels"] || filters[:labels] || [])

  query = [] |> maybe_put(:search, search) |> maybe_put(:labels, labels)
  ~p"/gao_notes/notes?#{query}"
end

def exact_label(key, value), do: index(%{labels: ["#{key}=#{value}"]})
```

Change the existing Notes LiveView's private path function to call `NotesPath.index/1` without changing parsing semantics.

Add `GaoNoteLive.DashboardLive` using `assign_async/4` around `GaoNote.list_category_groups/0`. Render DuskMoon cards and semantic links styled with DuskMoon chip classes, with loading skeleton, unavailable state, configured-empty message, and no-config CTA. Add `live("/gao_notes", GaoNoteLive.DashboardLive, :index)` and menu item `%{id: "gao_note_dashboard", label: "Dashboard", path: "/gao_notes", exact: true}` before Note List. Extend `AdminMenu.path_matches?/2` to honor `exact: true`, so unknown legacy paths under `/gao_notes` do not become Dashboard-active.

- [ ] **Step 4: Run focused admin tests and verify GREEN**

Run the Step 2 command. Expected: all dashboard, navigation, and URL tests pass.

### Task 5: Configure selectors on Label Settings

**Files:**
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/label_setting_live/index.ex`
- Modify: `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_label_live_test.exs`

- [ ] **Step 1: Write failing selector-form tests**

Test key-wide `project`, exact `type=skill`, `type=agent` on the same key, duplicate prevention, trim normalization, remove/re-add ordering, save/clear persistence, invalid typed-value feedback, and configured-key deletion instructions. Drive the real LiveView events/forms.

```elixir
view |> form("#gao-note-category-form", %{"category" => %{"label_setting_id" => type.id, "value" => " skill "}}) |> render_change()
view |> element("#gao-note-category-add") |> render_click()
view |> element("#gao-note-category-save") |> render_click()

assert [%{key: "type", configured_value: "skill"}] = GaoNote.list_category_groups()
```

- [ ] **Step 2: Run the focused Label Settings test and verify RED**

Run:

```bash
devenv shell -- env DATABASE_URL=postgres://gsmlg_dev:gsmlg_dev@localhost:5433/gsmlg_dev \
  mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_label_live_test.exs
```

Expected: category controls/events are missing.

- [ ] **Step 3: Implement the ordered draft and save flow**

Add LiveView assigns for `category_settings`, `category_draft`, selected label ID, and optional value. Load saved selectors asynchronously alongside the catalog. Add events:

```elixir
handle_event("category_changed", params, socket)
handle_event("add_category", _params, socket)
handle_event("remove_category", %{"position" => position}, socket)
handle_event("save_categories", _params, socket)
```

The displayed selection uses the local draft once edited and otherwise the asynchronously loaded saved groups. Add appends normalized selectors, rejects an identical local selector, and permits different values for the same key. Save calls `GaoNote.save_category_settings/1`, refreshes async data, clears the draft, and shows a precise validation message on error.

Render a DuskMoon card above the label table with the existing-key select, optional exact-value input, Add button, semantic removable buttons styled with DuskMoon chip classes, and Save button. For label rows with `category_count > 0`, disable deletion and expose: `Remove every category using this label from Category labels before deleting it.`

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the Step 2 command. Expected: all Label Settings tests pass, including existing unique-control coverage.

### Task 6: Verify, review, and commit the scoped feature

**Files:** All files listed in the File Map, and no unrelated paths.

- [ ] **Step 1: Format only modified Elixir files**

Run `mix format` with the explicit modified `.ex`/`.exs` paths. Do not format unrelated files.

- [ ] **Step 2: Run scoped verification**

Run:

```bash
devenv shell -- env DATABASE_URL=postgres://gsmlg_dev:gsmlg_dev@localhost:5433/gsmlg_dev \
  mix test apps/gsmlg_gao_note/test apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_label_live_test.exs apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_dashboard_live_test.exs apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs apps/gsmlg_admin_web/test/gsmlg/admin_web/components/admin_navigation_test.exs

devenv shell -- mix compile --warnings-as-errors
git diff --check
```

If any out-of-scope test fails, report it and stop rather than modifying unrelated code. The strict compile check may expose pre-existing warnings in attachment/admin modules; record those separately and do not widen the feature to repair them.

- [ ] **Step 3: Review the exact diff and working tree**

Confirm every changed line traces to the approved design. Preserve the unrelated untracked `gsmlg-web-api-discovery` spec/plan files and any new user changes.

- [ ] **Step 4: Commit and push directly to main**

Stage only the GaoNote category files from the File Map, then create one conventional commit:

```bash
git commit -m "feat(gao-note): add category dashboard"
git push origin main
```

Verify `git rev-parse HEAD` equals `git ls-remote origin refs/heads/main`.

### Task 7: Release the next minor version and deploy `vultr-01`

**Files:**
- Read-only: `.github/workflows/release.yml`
- Read-only: `scripts/update_version.sh`

- [ ] **Step 1: Resolve immutable release inputs from live state**

After push, capture `RELEASE_REV=$(git rev-parse HEAD)` and re-query `gh release list`. The read-only planning audit found `v5.9.2` as the latest stable release, so the intended next minor is `v5.10.0`; revalidate that live state and confirm `v5.10.0` still does not exist before dispatch.

- [ ] **Step 2: Dispatch and monitor the manual release workflow**

```bash
gh workflow run release.yml --ref main \
  -f release-version=5.10.0 \
  -f revision="$RELEASE_REV"
```

Identify the resulting run as `RUN_ID` and poll `gh run view "$RUN_ID" --json status,conclusion,headSha,jobs,url` until completion. Stop before deployment if any release job fails.

- [ ] **Step 3: Verify GitHub release and registry publication**

Verify `gh release view v5.10.0` shows the umbrella, scout-agent, and six Commander tarballs plus Docker instructions. Verify remote `main` and `refs/tags/v5.10.0` resolve to `$RELEASE_REV`. Inspect the GHCR `v5.10.0` and `latest` manifests before touching the host.

- [ ] **Step 4: Restart the root-managed production service**

On `vultr-01`, inspect `podman-gsmlg-umbrella.service`, then restart it only after publication proof. The unit's `--pull=always` behavior must pull the newly published `latest` image.

- [ ] **Step 5: Prove the deployment**

After startup settles, verify:

- `podman-gsmlg-umbrella.service` is active/running.
- `NRestarts=0`.
- The running image label reports `version=5.10.0`.
- The running container image identity matches the published image.
- The public web endpoint returns HTTP 200.
- The admin endpoint redirects to sign-in with HTTP 302.
- Recent service logs contain no boot/migration failure.

Only after every check passes is the release/deployment objective complete.
