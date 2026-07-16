# GaoNote Attachments Hard-Break Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove GaoNote References and replace every GaoNote Asset surface with the single Attachment domain, database, HTTP, MCP, and admin contract.

**Architecture:** Preserve existing storage-backed rows by renaming `gao_note_assets` to `gao_note_attachments` in an idempotent compatibility migration while fresh databases create only the final table. Convert the domain context first, then move public HTTP, MCP, and admin LiveView callers onto `Attachment`; delete Reference code rather than retaining compatibility aliases.

**Tech Stack:** Elixir 1.18, Ecto/PostgreSQL, Phoenix 1.8 LiveView, Backplane MCP, phoenix_duskmoon, ExUnit, devenv.

---

## File Structure

The implementation changes these units:

- `apps/gsmlg/priv/repo/migrations/20260612000004_create_gao_note_references.exs`: delete so fresh databases never create Reference storage.
- `apps/gsmlg/priv/repo/migrations/20260612000005_create_gao_note_assets.exs`: move to `20260612000005_create_gao_note_attachments.exs` and create the final table directly.
- `apps/gsmlg/priv/repo/migrations/20260714000000_replace_gao_note_assets_with_attachments.exs`: create the compatibility migration for the current database.
- `apps/gsmlg_gao_note/lib/gsmlg/gao_note/reference.ex`: delete the Reference domain.
- `apps/gsmlg_gao_note/lib/gsmlg/gao_note/asset.ex`: move to `attachment.ex`; the file owns attachment validation and note-relative paths.
- `apps/gsmlg_gao_note/lib/gsmlg/gao_note/note.ex`: expose `has_many :attachments` only.
- `apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex`: own attachment queries and mutations; remove Reference and Asset APIs.
- `apps/gsmlg_gao_note/lib/gsmlg/gao_note/presenter.ex`: emit the final attachment JSON contract and enforce storage visibility.
- `apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/{tools,resources,admin_server,readonly_server}.ex`: expose attachment-only MCP names.
- `apps/gsmlg_web/lib/gsmlg/web/{router.ex,controllers/gao_note_controller.ex,controllers/gao_note_json.ex}`: expose `/attachments` and remove old endpoints.
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/attachment_live/index.ex`: own global and note-specific attachment management.
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/{router.ex,admin_menu.ex}` and GaoNote note/MCP LiveViews: link only to Attachments.
- GaoNote tests in `apps/gsmlg_gao_note/test`, `apps/gsmlg_web/test`, and `apps/gsmlg_admin_web/test`: assert the hard-break contract and remove stale Tag/Reference/Asset expectations.

### Task 1: Establish the Attachment Schema and Database Migration

**Files:**

- Delete: `apps/gsmlg/priv/repo/migrations/20260612000004_create_gao_note_references.exs`
- Move: `apps/gsmlg/priv/repo/migrations/20260612000005_create_gao_note_assets.exs` -> `apps/gsmlg/priv/repo/migrations/20260612000005_create_gao_note_attachments.exs`
- Create: `apps/gsmlg/priv/repo/migrations/20260714000000_replace_gao_note_assets_with_attachments.exs`
- Move: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/asset.ex` -> `apps/gsmlg_gao_note/lib/gsmlg/gao_note/attachment.ex`
- Delete: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/reference.ex`
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/note.ex`
- Modify: `apps/gsmlg/priv/repo/migrations/20260612000003_create_gao_note_labels.exs`
- Test: `apps/gsmlg_gao_note/test/gsmlg/gao_note_test.exs`

- [ ] **Step 1: Write the failing schema test**

Replace the test alias for `Asset` and `Reference` with `Attachment`, then add:

```elixir
alias GSMLG.GaoNote.Attachment

test "attachment schema uses the final table and defaults" do
  assert Attachment.__schema__(:source) == "gao_note_attachments"

  changeset =
    Attachment.changeset(%Attachment{}, %{
      note_id: Ecto.UUID.generate(),
      storage_file_id: Ecto.UUID.generate(),
      path: "data.txt"
    })

  assert changeset.valid?
  assert Ecto.Changeset.get_field(changeset, :description) == ""
  assert Ecto.Changeset.get_field(changeset, :path) == "./data.txt"
end
```

- [ ] **Step 2: Run the schema test and verify it fails**

Run:

```bash
devenv shell -- unbuffer mix test apps/gsmlg_gao_note/test/gsmlg/gao_note_test.exs
```

Expected: compilation fails because `GSMLG.GaoNote.Attachment` is not defined.

- [ ] **Step 3: Rename the schema and define the final association**

Move the file and make its final declarations:

```elixir
defmodule GSMLG.GaoNote.Attachment do
  use Ecto.Schema
  import Ecto.Changeset

  alias GSMLG.GaoNote.Note
  alias GSMLG.Storage.StorageFile

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]
  @roles ~w(attachment cover inline source)

  schema "gao_note_attachments" do
    belongs_to(:note, Note)
    belongs_to(:storage_file, StorageFile)
    field(:role, :string, default: "attachment")
    field(:description, :string, default: "")
    field(:path, :string)
    field(:caption, :string)
    field(:alt_text, :string)
    field(:position, :integer, default: 0)
    field(:metadata, :map, default: %{})
    timestamps()
  end

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [
      :note_id,
      :storage_file_id,
      :role,
      :description,
      :path,
      :caption,
      :alt_text,
      :position,
      :metadata
    ])
    |> put_default_description()
    |> normalize_path()
    |> validate_required([:note_id, :storage_file_id])
    |> validate_inclusion(:role, @roles)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_note_relative_path()
    |> unique_constraint([:note_id, :storage_file_id])
    |> unique_constraint([:note_id, :path], name: :gao_note_attachments_note_id_path_index)
  end

  defp put_default_description(changeset) do
    case get_field(changeset, :description) do
      nil -> put_change(changeset, :description, "")
      _description -> changeset
    end
  end

  defp normalize_path(changeset) do
    case get_change(changeset, :path) do
      path when is_binary(path) ->
        path = String.trim(path)

        cond do
          path == "" -> put_change(changeset, :path, nil)
          String.starts_with?(path, "./") -> put_change(changeset, :path, path)
          true -> put_change(changeset, :path, "./#{path}")
        end

      _path ->
        changeset
    end
  end

  defp validate_note_relative_path(changeset) do
    validate_change(changeset, :path, fn :path, path ->
      cond do
        is_nil(path) -> []
        String.starts_with?(path, "/") -> [path: "must be relative to the note, for example ./data.txt"]
        String.contains?(path, "..") -> [path: "must not contain .."]
        String.contains?(path, "://") -> [path: "must not be an absolute URL"]
        not String.starts_with?(path, "./") -> [path: "must start with ./"]
        true -> []
      end
    end)
  end
end
```

In `Note`, replace both subordinate associations with:

```elixir
alias GSMLG.GaoNote.{Attachment, Label}

has_many(:attachments, Attachment, foreign_key: :note_id)
has_many(:labels, Label, foreign_key: :note_id)
```

- [ ] **Step 4: Rewrite fresh migrations and add the compatibility migration**

Rename the historical migration module to `CreateGaoNoteAttachments`, create `gao_note_attachments`, and name every index with the `gao_note_attachments_*` prefix. Remove `timestamps()` from `gao_note_labels`; the join schema has no timestamp fields and otherwise fresh-database label inserts violate non-null constraints.

Create the compatibility migration with this behavior:

```elixir
defmodule GSMLG.Repo.Migrations.ReplaceGaoNoteAssetsWithAttachments do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF to_regclass('public.gao_note_attachments') IS NULL
         AND to_regclass('public.gao_note_assets') IS NOT NULL THEN
        ALTER TABLE gao_note_assets RENAME TO gao_note_attachments;
      END IF;
    END $$;
    """)

    execute("ALTER INDEX IF EXISTS gao_note_assets_note_id_index RENAME TO gao_note_attachments_note_id_index")
    execute("ALTER INDEX IF EXISTS gao_note_assets_storage_file_id_index RENAME TO gao_note_attachments_storage_file_id_index")
    execute("ALTER INDEX IF EXISTS gao_note_assets_note_id_storage_file_id_index RENAME TO gao_note_attachments_note_id_storage_file_id_index")
    execute("ALTER INDEX IF EXISTS gao_note_assets_note_id_path_index RENAME TO gao_note_attachments_note_id_path_index")

    drop_if_exists(table(:gao_note_references))

    execute("""
    UPDATE storage_files
    SET type = 'attachment'
    WHERE tenant = 'gao_note' AND type = 'asset'
    """)
  end

  def down, do: :ok
end
```

- [ ] **Step 5: Apply the compatibility migration**

Run:

```bash
devenv shell -- mix ecto.migrate
```

Expected: the migration succeeds, preserves attachment rows, drops `gao_note_references`, and records migration `20260714000000`.

- [ ] **Step 6: Run the schema test and commit**

Run:

```bash
devenv shell -- unbuffer mix test apps/gsmlg_gao_note/test/gsmlg/gao_note_test.exs
```

Expected: the new schema test passes; remaining failures may still mention old context APIs.

Commit only Task 1 paths:

```bash
git add apps/gsmlg/priv/repo/migrations apps/gsmlg_gao_note/lib/gsmlg/gao_note/attachment.ex apps/gsmlg_gao_note/lib/gsmlg/gao_note/asset.ex apps/gsmlg_gao_note/lib/gsmlg/gao_note/reference.ex apps/gsmlg_gao_note/lib/gsmlg/gao_note/note.ex apps/gsmlg_gao_note/test/gsmlg/gao_note_test.exs
git commit -m "refactor(gao_note): establish attachment persistence"
```

### Task 2: Replace Context Reference and Asset APIs

**Files:**

- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex`
- Test: `apps/gsmlg_gao_note/test/gsmlg/gao_note_test.exs`

- [ ] **Step 1: Replace domain lifecycle tests with Attachment behavior**

Delete the entire `describe "references"` block. Replace the asset block with tests using the final API:

```elixir
describe "attachments" do
  test "attach, list, update, and detach an attachment" do
    note = note_fixture()
    file = storage_file_fixture(%{type: "attachment", filename: "data.txt"})

    assert {:ok, %Attachment{} = attachment} =
             GaoNote.attach_existing_file(
               note,
               file.id,
               %{description: "Dataset", path: "./data.txt"},
               actor()
             )

    assert attachment.description == "Dataset"
    assert attachment.path == "./data.txt"
    assert %Attachment{id: id} = GaoNote.get_attachment(attachment.id)
    assert id == attachment.id
    assert [%Attachment{id: ^id}] = GaoNote.list_attachments(note)
    assert [%Attachment{id: ^id, note: %Note{id: note_id}}] = GaoNote.list_all_attachments()
    assert note_id == note.id

    assert {:ok, %Attachment{description: "Updated"}} =
             GaoNote.update_attachment(attachment, %{description: "Updated"}, actor())

    assert {:ok, %Attachment{id: ^id}} = GaoNote.detach_attachment(attachment, actor())
    assert GaoNote.get_attachment(id) == nil
  end

  test "attachment operations reject a logically deleted parent note" do
    note = note_fixture()
    file = storage_file_fixture(%{type: "attachment"})
    assert {:ok, attachment} = GaoNote.attach_existing_file(note, file.id, %{}, actor())
    assert {:ok, _deleted} = GaoNote.delete_note(note, actor())

    assert GaoNote.get_attachment(attachment.id) == nil
    assert GaoNote.list_attachments(note) == []
    assert {:error, :note_not_active} =
             GaoNote.update_attachment(attachment, %{description: "blocked"}, actor())
  end
end
```

- [ ] **Step 2: Run the context test and verify old APIs fail**

Run:

```bash
devenv shell -- unbuffer mix test apps/gsmlg_gao_note/test/gsmlg/gao_note_test.exs
```

Expected: failures report undefined `attach_existing_file/4`, `list_attachments/1`, and related Attachment functions.

- [ ] **Step 3: Implement the Attachment context API**

Replace the context aliases and public functions with these signatures and query boundaries:

```elixir
alias GSMLG.GaoNote.{Attachment, Label, LabelSetting, Log, MCPSetting, Note}

def list_attachments(note_or_id) do
  note_id = note_id(note_or_id)

  Attachment
  |> join(:inner, [attachment], file in assoc(attachment, :storage_file))
  |> join(:inner, [attachment, _file], note in assoc(attachment, :note))
  |> where(
    [attachment, file, note],
    attachment.note_id == ^note_id and file.status == "active" and is_nil(note.deleted_at)
  )
  |> order_by([attachment], asc: attachment.position, asc: attachment.inserted_at)
  |> preload([_attachment, file, _note], storage_file: file)
  |> Repo.all()
end

def list_all_attachments(opts \\ []) do
  opts = normalize_opts(opts)

  Attachment
  |> join(:inner, [attachment], file in assoc(attachment, :storage_file))
  |> join(:inner, [attachment, _file], note in assoc(attachment, :note))
  |> where([_attachment, file, note], file.status == "active" and is_nil(note.deleted_at))
  |> order_by([attachment], desc: attachment.inserted_at)
  |> limit(^limit_value(opts[:limit]))
  |> offset(^offset_value(opts[:offset]))
  |> preload([_attachment, file, note], storage_file: file, note: note)
  |> Repo.all()
end

def get_attachment(id) do
  with {:ok, id} <- Ecto.UUID.cast(id) do
    Attachment
    |> join(:inner, [attachment], note in assoc(attachment, :note))
    |> where([_attachment, note], is_nil(note.deleted_at))
    |> preload(:storage_file)
    |> Repo.get(id)
  else
    :error -> nil
  end
end

def change_attachment(%Attachment{} = attachment, attrs \\ %{}) do
  Attachment.changeset(attachment, attrs)
end
```

Keep the existing storage-file activity check and path defaulting while renaming mutations to:

```elixir
attach_existing_file/4
upload_attachment/4
update_attachment/3
detach_attachment/2
```

Use `Storage.upload(upload_input, "gao_note", "attachment", ...)`, log entity type `"attachment"`, and return `{:error, :note_not_active}` from update/detach when `get_note(attachment.note_id)` is nil.

- [ ] **Step 4: Remove all Reference behavior from note creation and context helpers**

Delete `list_references/1`, `list_all_references/1`, `get_reference/1`, `change_reference/2`, `add_reference/3`, `update_reference/3`, `remove_reference/2`, and `add_references_in_repo/2`. Remove `:references` extraction and the `Multi.run(:references, ...)` step from `create_note/2`.

Every note preload becomes:

```elixir
preload([labels: :label_setting, attachments: :storage_file])
```

and the helper becomes:

```elixir
defp preload_note(%Note{} = note) do
  Repo.preload(note, [labels: :label_setting, attachments: :storage_file], force: true)
end
```

- [ ] **Step 5: Run context tests and commit**

Run:

```bash
devenv shell -- unbuffer mix test apps/gsmlg_gao_note/test/gsmlg/gao_note_test.exs
```

Expected: Attachment lifecycle and soft-delete tests pass; no domain test invokes a Reference or Asset API.

Commit:

```bash
git add apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex apps/gsmlg_gao_note/test/gsmlg/gao_note_test.exs
git commit -m "refactor(gao_note): expose attachment context API"
```

### Task 3: Implement Attachment Serialization and Visibility

**Files:**

- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/presenter.ex`
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex`
- Test: `apps/gsmlg_gao_note/test/gsmlg/gao_note_test.exs`

- [ ] **Step 1: Add failing serialization tests**

Add:

```elixir
test "note serialization exposes attachments and never legacy keys" do
  note = note_fixture()
  file = storage_file_fixture(%{
    type: "attachment",
    filename: "data.txt",
    metadata: %{"visibility" => "private"}
  })

  assert {:ok, attachment} =
           GaoNote.attach_existing_file(note, file.id, %{path: "./data.txt"}, actor())

  rendered = note.id |> GaoNote.get_note() |> GSMLG.GaoNote.Presenter.note()

  assert [%{"id" => id, "path" => "./data.txt", "content" => nil}] =
           rendered["attachments"]

  assert id == attachment.id
  refute Map.has_key?(rendered, "assets")
  refute Map.has_key?(rendered, "references")
end

test "list results do not replace loaded attachments with an empty list" do
  note = note_fixture()
  file = storage_file_fixture(%{type: "attachment", filename: "list.txt"})
  assert {:ok, _attachment} = GaoNote.attach_existing_file(note, file.id, %{}, actor())

  assert [%Note{} = listed] = GaoNote.list_notes(search: note.title)
  assert [_attachment] = listed.attachments
end
```

- [ ] **Step 2: Run tests and verify serialization fails**

Run:

```bash
devenv shell -- unbuffer mix test apps/gsmlg_gao_note/test/gsmlg/gao_note_test.exs
```

Expected: presenter still references `%Asset{}` or list queries leave `attachments` unloaded.

- [ ] **Step 3: Replace presenter Asset and Reference functions**

Use `Attachment` and emit one string-keyed representation:

```elixir
alias GSMLG.GaoNote.{Attachment, Label, LabelSetting, Note}

def attachment(%Attachment{} = attachment, %Note{} = note) do
  storage_file = loaded_storage_file(attachment)

  base = %{
    "id" => attachment.id,
    "description" => attachment.description || "",
    "path" => attachment_path(attachment, storage_file),
    "mime" => storage_mime(storage_file),
    "content" => public_attachment_content(storage_file),
    "storage_file_id" => attachment.storage_file_id,
    "role" => attachment.role,
    "caption" => attachment.caption,
    "alt_text" => attachment.alt_text,
    "position" => attachment.position,
    "metadata" => attachment.metadata || %{}
  }

  case public_file_url(attachment, note, storage_file) do
    nil -> base
    url -> Map.put(base, "url", url)
  end
end

defp public_attachment_content(%StorageFile{} = file) do
  visible? = get_in(file.metadata || %{}, ["visibility"]) == "public"
  text? = String.starts_with?(file.content_type || "", "text/")

  if visible? and text? and is_integer(file.size) and file.size <= 128_000 do
    case Storage.stream(file) do
      {:ok, content} when is_binary(content) and String.valid?(content) -> content
      {:ok, _invalid_utf8} -> nil
      {:error, _reason} -> nil
    end
  end
end

defp public_attachment_content(_file), do: nil
```

Delete `reference/1`, `asset/2`, and `asset_json/2`. Update `note/1` to map loaded `:attachments` through `attachment/2`.

- [ ] **Step 4: Preload attachment metadata for note lists**

In `list_notes_from/2`, use:

```elixir
preload([labels: :label_setting, attachments: :storage_file])
```

This uses Ecto's separate preload query for the has-many association and prevents false `attachments: []` summaries.

- [ ] **Step 5: Run tests and commit**

Run:

```bash
devenv shell -- unbuffer mix test apps/gsmlg_gao_note/test/gsmlg/gao_note_test.exs
```

Expected: serialization tests pass and private attachment content remains nil.

Commit:

```bash
git add apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex apps/gsmlg_gao_note/lib/gsmlg/gao_note/presenter.ex apps/gsmlg_gao_note/test/gsmlg/gao_note_test.exs
git commit -m "refactor(gao_note): serialize attachments"
```

### Task 4: Replace Public Reference and Asset APIs

**Files:**

- Modify: `apps/gsmlg_web/lib/gsmlg/web/router.ex`
- Modify: `apps/gsmlg_web/lib/gsmlg/web/controllers/gao_note_controller.ex`
- Modify: `apps/gsmlg_web/lib/gsmlg/web/controllers/gao_note_json.ex`
- Test: `apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_controller_test.exs`

- [ ] **Step 1: Write the attachment endpoint test and legacy-route assertions**

Replace Reference and Asset tests with:

```elixir
describe "attachments" do
  test "lists attachments using the final contract", %{conn: conn} do
    note = note_fixture()
    file = storage_file_fixture(%{
      type: "attachment",
      metadata: %{"visibility" => "public"}
    })

    assert {:ok, attachment} =
             GaoNote.attach_existing_file(
               note,
               file.id,
               %{path: "./gao-note.txt", description: "Example"},
               actor()
             )

    conn = get(conn, ~p"/api/gao_notes/#{note.id}/attachments")

    assert %{"data" => [rendered]} = json_response(conn, 200)
    assert rendered["id"] == attachment.id
    assert rendered["path"] == "./gao-note.txt"
    assert rendered["description"] == "Example"
    assert rendered["mime"] == "text/plain"
    refute Map.has_key?(rendered, "asset_id")
  end

  test "legacy Reference and Asset routes are absent", %{conn: conn} do
    note = note_fixture()
    assert json_response(get(conn, "/api/gao_notes/#{note.id}/references"), 404)
    assert json_response(get(conn, "/api/gao_notes/#{note.id}/assets"), 404)
  end
end
```

Update setup aliases and fixtures to `Attachment`, `Label`, and `LabelSetting`; use `labels` and `label` rather than stale Tag names.

- [ ] **Step 2: Run the controller test and verify the new route is missing**

Run:

```bash
devenv shell -- unbuffer mix test apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_controller_test.exs
```

Expected: `/attachments` returns 404 or the controller lacks `attachments/2`.

- [ ] **Step 3: Replace router, controller, and JSON actions**

The router retains only:

```elixir
get("/gao_notes/:id/attachments", GaoNoteController, :attachments)
```

The controller action is:

```elixir
def attachments(conn, %{"id" => id}) do
  with %{} = note <- GaoNote.get_public_note(id) do
    attachments = GaoNote.list_attachments(note)
    render(conn, :attachments, note: note, attachments: attachments)
  else
    nil -> {:error, :not_found}
  end
end
```

The JSON action is:

```elixir
def attachments(%{note: note, attachments: attachments}) do
  %{data: Enum.map(attachments, &Presenter.attachment(&1, note))}
end
```

Delete controller/JSON Reference actions and Asset actions.

- [ ] **Step 4: Run public tests and commit**

Run:

```bash
devenv shell -- unbuffer mix test apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_controller_test.exs apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_mcp_controller_test.exs
```

Expected: controller tests pass; MCP tests may still fail on old MCP component names.

Commit:

```bash
git add apps/gsmlg_web/lib/gsmlg/web/router.ex apps/gsmlg_web/lib/gsmlg/web/controllers/gao_note_controller.ex apps/gsmlg_web/lib/gsmlg/web/controllers/gao_note_json.ex apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_controller_test.exs
git commit -m "refactor(gao_note): expose attachment HTTP API"
```

### Task 5: Replace MCP Tools and Resources

**Files:**

- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/tools.ex`
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/resources.ex`
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/admin_server.ex`
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/readonly_server.ex`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/mcp_live/index.ex`
- Test: `apps/gsmlg_gao_note/test/gsmlg/gao_note/mcp_test.exs`
- Test: `apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_mcp_controller_test.exs`
- Test: `apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/gao_note_mcp_controller_test.exs`

- [ ] **Step 1: Change MCP tests to the final names**

Assert these exact names:

```elixir
readonly_names = tool_names(GSMLG.GaoNote.MCP.ReadOnlyServer)
assert "gao_note.list_attachments" in readonly_names
refute Enum.any?(readonly_names, &String.contains?(&1, "references"))
refute Enum.any?(readonly_names, &String.contains?(&1, "assets"))

admin_names = tool_names(GSMLG.GaoNote.MCP.AdminServer)
assert "gao_note.attachments.attach_existing" in admin_names
assert "gao_note.attachments.upload_base64" in admin_names
assert "gao_note.attachments.update" in admin_names
assert "gao_note.attachments.detach" in admin_names
```

Add a schema assertion:

```elixir
update_tool = tool(GSMLG.GaoNote.MCP.AdminServer, "gao_note.attachments.update")
assert "attachment_id" in tool_property_names(update_tool)
refute "asset_id" in tool_property_names(update_tool)
```

Add a resource read assertion for `gaonote://notes/#{note.id}/attachments` and remove every Reference tool call.

- [ ] **Step 2: Run MCP tests and verify old components fail**

Run:

```bash
devenv shell -- unbuffer mix test apps/gsmlg_gao_note/test/gsmlg/gao_note/mcp_test.exs
```

Expected: new tool/resource names are not registered.

- [ ] **Step 3: Replace tool names, schemas, dispatch, and component modules**

The tool sets become:

```elixir
@readonly_tools ~w(
  gao_note.search
  gao_note.get
  gao_note.list_label_settings
  gao_note.list_attachments
)

@admin_tools @readonly_tools ++
  ~w(
    gao_note.create
    gao_note.create_label_setting
    gao_note.update
    gao_note.delete
    gao_note.set_labels
    gao_note.attachments.attach_existing
    gao_note.attachments.upload_base64
    gao_note.attachments.update
    gao_note.attachments.detach
  )
```

Rename every Asset input and dispatch value to Attachment, including
`attachment_id`. Dispatch through `get_attachment/1`, `attach_existing_file/4`,
`upload_attachment/4`, `update_attachment/3`, and `detach_attachment/2`.
Return structured content under `"attachment"` or `"attachments"` and serialize
with `Presenter.attachment/2`.

Define components with these module names:

```elixir
GSMLG.GaoNote.MCP.Tools.ListAttachments
GSMLG.GaoNote.MCP.Tools.AttachExistingAttachment
GSMLG.GaoNote.MCP.Tools.UploadBase64Attachment
GSMLG.GaoNote.MCP.Tools.UpdateAttachment
GSMLG.GaoNote.MCP.Tools.DetachAttachment
```

Delete `AddReference`, `UpdateReference`, and `RemoveReference` components.

- [ ] **Step 4: Replace MCP resources and server registration**

Resource URI handling becomes:

```elixir
%URI{scheme: "gaonote", host: "attachments", path: "/" <> attachment_id} ->
  read_attachment(uri, attachment_id, frame)
```

and note subresources accept only `"attachments"`. Define:

```elixir
GSMLG.GaoNote.MCP.Resources.NoteAttachments
  uri_template: "gaonote://notes/{id}/attachments"
  name: "gao_note.note.attachments"

GSMLG.GaoNote.MCP.Resources.Attachment
  uri_template: "gaonote://attachments/{attachment_id}"
  name: "gao_note.attachment"
```

Register only these attachment components in both MCP servers. Remove all
Reference and Asset registrations.

- [ ] **Step 5: Update the admin MCP inspector**

Its resources list contains:

```elixir
%{
  name: "gao_note.note.attachments",
  uri: "gaonote://notes/{id}/attachments",
  mime_type: "application/json"
},
%{
  name: "gao_note.attachment",
  uri: "gaonote://attachments/{attachment_id}",
  mime_type: "application/json"
}
```

Its defaults use:

```elixir
defp default_arguments_json("gao_note.attachments.attach_existing"),
  do: ~s({"id": "", "storage_file_id": ""})

defp default_arguments_json("gao_note.attachments.upload_base64"),
  do: ~s({"id": "", "filename": "", "base64": ""})

defp default_arguments_json("gao_note.attachments.update"),
  do: ~s({"attachment_id": ""})

defp default_arguments_json("gao_note.attachments.detach"),
  do: ~s({"attachment_id": ""})
```

- [ ] **Step 6: Run MCP tests and commit**

Run:

```bash
devenv shell -- unbuffer mix test apps/gsmlg_gao_note/test/gsmlg/gao_note/mcp_test.exs apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_mcp_controller_test.exs apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/gao_note_mcp_controller_test.exs
```

Expected: all MCP tests pass with no Reference or Asset names.

Commit:

```bash
git add apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp apps/gsmlg_gao_note/test/gsmlg/gao_note/mcp_test.exs apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_mcp_controller_test.exs apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/mcp_live/index.ex apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/gao_note_mcp_controller_test.exs
git commit -m "refactor(gao_note): replace MCP assets with attachments"
```

### Task 6: Replace Admin Reference and Asset Pages with Attachments

**Files:**

- Delete: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/reference_live/index.ex`
- Move: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/asset_live/index.ex` -> `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/attachment_live/index.ex`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/index.ex`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/router.ex`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/admin_menu.ex`
- Test: `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs`
- Test: `apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs`

- [ ] **Step 1: Write menu and route expectations first**

Update the GaoNote menu assertion to exactly:

```elixir
assert [
         %{id: "gao_note_list", label: "Note List", path: "/gao_notes/notes"},
         %{
           id: "gao_note_label_settings",
           label: "Label Settings",
           path: "/gao_notes/label_settings"
         },
         %{
           id: "gao_note_attachments",
           label: "Attachments",
           path: "/gao_notes/attachments"
         },
         %{
           id: "gao_note_recycle_bin",
           label: "Recycle Bin",
           path: "/gao_notes/recycle_bin"
         },
         %{id: "gao_note_logs", label: "Log", path: "/gao_notes/logs"},
         %{id: "gao_note_mcp", label: "MCP", path: "/gao_notes/mcp"}
       ] = gao_notes.items
```

Assert path matching returns `gao_note_attachments` for
`/gao_notes/attachments` and refute both old menu IDs.

Replace the global Asset LiveView test with:

```elixir
test "admin can open the global attachments page", %{conn: conn, user: user} do
  assert {:ok, note} =
           GaoNote.create_note(%{title: "Attachment Note", content: "Body"}, user)

  file = storage_file_fixture(%{type: "attachment", filename: "data.txt"})
  assert {:ok, _attachment} =
           GaoNote.attach_existing_file(note, file.id, %{path: "./data.txt"}, user)

  {:ok, _view, html} = live(conn, ~p"/gao_notes/attachments")
  assert html =~ "GaoNote Attachments"
  assert html =~ ~s(id="gao-note-attachments-table")
  assert html =~ "Attachment Note"
  assert html =~ "data.txt"
end
```

- [ ] **Step 2: Run admin tests and verify routes/menu fail**

Run:

```bash
devenv shell -- unbuffer mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs
```

Expected: the Attachments menu and LiveView route are missing.

- [ ] **Step 3: Rename the LiveView and all UI terminology**

The renamed module starts with:

```elixir
defmodule GSMLG.AdminWeb.GaoNoteLive.AttachmentLive.Index do
  use GSMLG.AdminWeb, :user_live_view

  alias GSMLG.GaoNote
end
```

Use assigns `:attachments`, form namespace `:attachment`, active menu
`"gao_note_attachments"`, headings `GaoNote Attachments`, and DOM IDs prefixed
`gao-note-attachments`. Call only the final Attachment context functions.

Preserve the client filename during LiveView uploads:

```elixir
consume_uploaded_entries(socket, :attachment, fn %{path: path}, entry ->
  upload = %Plug.Upload{
    path: path,
    filename: entry.client_name,
    content_type: entry.client_type
  }

  metadata = %{"original_name" => entry.client_name, "visibility" => "private"}
  attrs = Map.put(attrs, "metadata", metadata)

  case GaoNote.upload_attachment(note, upload, attrs, actor) do
    {:ok, attachment} -> {:ok, {:ok, attachment}}
    {:error, reason} -> {:ok, {:error, reason}}
  end
end)
```

Storage still detects MIME from bytes, so `entry.client_type` is not trusted for
validation.

- [ ] **Step 4: Replace admin routes, menu, and note actions**

Router entries become:

```elixir
live("/gao_notes/notes/:id/attachments", GaoNoteLive.AttachmentLive.Index, :index)
live("/gao_notes/attachments", GaoNoteLive.AttachmentLive.Index, :all)
```

The menu contains only:

```elixir
%{id: "gao_note_attachments", label: "Attachments", path: "/gao_notes/attachments"}
```

Delete all Reference routes and links. In the note LiveView, remove
`:references`, rename `:assets` to `:attachments`, and link to:

```elixir
~p"/gao_notes/notes/#{note.id}/attachments"
```

- [ ] **Step 5: Run admin tests and commit**

Run:

```bash
devenv shell -- unbuffer mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs
```

Expected: the sidebar and both attachment pages pass, with no Reference or
Asset page assertion.

Commit:

```bash
git add apps/gsmlg_admin_web/lib/gsmlg/admin_web/admin_menu.ex apps/gsmlg_admin_web/lib/gsmlg/admin_web/router.ex apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs
git commit -m "refactor(gao_note): expose attachment admin pages"
```

### Task 7: Reconcile Existing Label Refactor Tests Blocking GaoNote Verification

**Files:**

- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/index.ex`
- Modify: `apps/gsmlg_gao_note/test/gsmlg/gao_note_test.exs`
- Modify: `apps/gsmlg_gao_note/test/gsmlg/gao_note/mcp_test.exs`
- Modify: `apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_controller_test.exs`
- Modify: `apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_mcp_controller_test.exs`
- Modify: `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs`
- Modify: `apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/gao_note_mcp_controller_test.exs`

- [ ] **Step 1: Replace mechanically stale Tag assertions**

Across the listed tests, use aliases `Label` and `LabelSetting`, cleanup with
`Repo.delete_all(Label)` before `Repo.delete_all(LabelSetting)`, pass labels as
`["Research=active"]`, and assert the final shape:

```elixir
assert [
         %{
           "key" => "Research",
           "value" => "active",
           "status" => "valid",
           "errors" => []
         }
       ] = rendered["labels"]
```

Use `gao_note.create_label_setting`, `gao_note.set_labels`, `labels`, and
`label_settings`; remove `create_tag`, `set_tags`, `tags`, `Tag`, and `Tagging`.
Replace the nonexistent `replace_label_settings/3` test call with:

```elixir
GaoNote.set_labels(note, ["Elixir=", "MCP Tools="], actor())
```

- [ ] **Step 2: Fix labeled-note editing and label filtering**

Initialize selected labels from the join records without losing values:

```elixir
selected_labels =
  Enum.map(note.labels, fn label ->
    key = label.label_setting.name
    if label.value in [nil, ""], do: key, else: "#{key}=#{label.value}"
  end)
```

The admin filter and MCP list options must pass the context key `:label`:

```elixir
label: blank_to_nil(filters["label"])
```

and:

```elixir
label: Map.get(args, "label")
```

- [ ] **Step 3: Make asynchronous label revalidation update a keyless join row**

Replace `Repo.update(label)` with a composite-key update:

```elixir
from(candidate in Label,
  where:
    candidate.note_id == ^label.note_id and
      candidate.label_setting_id == ^label.label_setting_id
)
|> Repo.update_all(set: [status: status, errors: errors])
```

This avoids `Ecto.NoPrimaryKeyValueError` while preserving the existing
composite unique key.

- [ ] **Step 4: Run all targeted GaoNote tests and commit**

Run:

```bash
devenv shell -- unbuffer mix test apps/gsmlg_gao_note/test apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_controller_test.exs apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_mcp_controller_test.exs apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/gao_note_mcp_controller_test.exs apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs
```

Expected: all targeted tests pass with final Label and Attachment terminology.

Commit:

```bash
git add apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/index.ex apps/gsmlg_gao_note/test apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_controller_test.exs apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_mcp_controller_test.exs apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/gao_note_mcp_controller_test.exs
git commit -m "fix(gao_note): align label and attachment tests"
```

### Task 8: Verify the Hard Break and Service Behavior

**Files:**

- Modify only if formatting changes are produced: all files changed in Tasks 1-7
- Test: all GaoNote-related test files listed above

- [ ] **Step 1: Scan for forbidden production and test terminology**

Run:

```bash
rg -n 'GSMLG\.GaoNote\.(Asset|Reference)|gao_note\.(assets|references)|gao_note_(assets|references)|/gao_notes/(assets|references)|asset_id|reference_id' apps/gsmlg_gao_note apps/gsmlg_web/lib apps/gsmlg_web/test apps/gsmlg_admin_web/lib apps/gsmlg_admin_web/test
```

Expected: no output. Generic Phoenix static assets and the compatibility
migration are outside this scan.

- [ ] **Step 2: Format all changed Elixir files**

Run:

```bash
devenv shell -- mix format apps/gsmlg/priv/repo/migrations apps/gsmlg_gao_note/lib apps/gsmlg_gao_note/test apps/gsmlg_web/lib/gsmlg/web/router.ex apps/gsmlg_web/lib/gsmlg/web/controllers/gao_note_controller.ex apps/gsmlg_web/lib/gsmlg/web/controllers/gao_note_json.ex apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_controller_test.exs apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_mcp_controller_test.exs apps/gsmlg_admin_web/lib/gsmlg/admin_web/admin_menu.ex apps/gsmlg_admin_web/lib/gsmlg/admin_web/router.ex apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/gao_note_mcp_controller_test.exs
```

Expected: command exits successfully.

- [ ] **Step 3: Verify a fresh test database migration**

Run:

```bash
devenv shell -- env MIX_ENV=test mix ecto.reset
```

Expected: fresh migrations create `gao_note_attachments`, never create
`gao_note_references`, and seed execution completes.

- [ ] **Step 4: Run strict compilation and GaoNote tests**

Run:

```bash
devenv shell -- mix compile --warnings-as-errors
devenv shell -- unbuffer mix test apps/gsmlg_gao_note/test apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_controller_test.exs apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_mcp_controller_test.exs apps/gsmlg_admin_web/test/gsmlg/admin_web/live/gao_note_live_test.exs apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/gao_note_mcp_controller_test.exs apps/gsmlg_admin_web/test/gsmlg/admin_web/admin_menu_test.exs
```

Expected: strict compilation and every targeted test pass.

- [ ] **Step 5: Restart services and smoke-test final routes**

Run:

```bash
devenv processes down && sleep 5 && devenv processes up -d
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:4110/api/gao_notes
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:4111/gao_notes/attachments
```

Expected: public API returns `200`; unauthenticated admin Attachments returns
the existing authentication redirect status.

- [ ] **Step 6: Commit final formatting or verification fixes**

If Step 2 changed formatting, commit only those path-scoped changes:

```bash
git add apps/gsmlg apps/gsmlg_gao_note apps/gsmlg_web apps/gsmlg_admin_web
git commit -m "chore(gao_note): finalize attachment hard break"
```

If formatting produced no diff, do not create an empty commit.
