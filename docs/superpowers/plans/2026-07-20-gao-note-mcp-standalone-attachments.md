# GaoNote MCP Standalone Attachments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add standalone GaoNote MCP operations to replace, delete, and read existing note attachments without sending the complete attachment collection through `update_note`.

**Architecture:** Keep initial attachment creation in the existing note aggregate path. Add targeted attachment lifecycle functions to `GSMLG.GaoNote.Attachments`, expose actor-aware wrappers from `GSMLG.GaoNote`, and register three minimal MCP tools. The read tool is available to readonly and admin MCP servers; replacement and deletion remain admin-only.

**Tech Stack:** Elixir 1.18, Ecto/PostgreSQL, Oban, `GSMLG.Storage` S3 storage, Backplane MCP Streamable HTTP, Peri schemas, ExUnit.

---

## File Map

- Modify `apps/gsmlg_gao_note/lib/gsmlg/gao_note/attachments.ex`
  - Own targeted attachment lookup, storage reads, replacement staging, row locking, persistence, and purge scheduling.
- Modify `apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex`
  - Expose actor-aware attachment operations and a note update path that preserves attachments.
- Modify `apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/tools.ex`
  - Define the three tool schemas, registration, access levels, annotations, dispatch, and Base64 response.
- Modify `apps/gsmlg_gao_note/test/gsmlg/gao_note_test.exs`
  - Cover domain replacement, retrieval, deletion, ownership, MIME, and rollback behavior.
- Modify `apps/gsmlg_gao_note/test/gsmlg/gao_note/mcp/aggregate_contract_test.exs`
  - Replace the aggregate-only MCP assertions with the approved standalone tool contract.
- Modify `apps/gsmlg_gao_note/test/gsmlg/gao_note/mcp_test.exs`
  - Cover direct MCP execution and access control.
- Modify `apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/gao_note_mcp_controller_test.exs`
  - Cover authenticated Streamable HTTP tool discovery and calls.
- Modify `apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_mcp_controller_test.exs`
  - Cover readonly discovery and content retrieval.

No new database migration or HTTP attachment CRUD controller is required.

## Task 1: Add Targeted Domain Attachment Operations

**Files:**

- Modify: `apps/gsmlg_gao_note/test/gsmlg/gao_note_test.exs`
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/attachments.ex`
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex`

- [ ] **Step 1: Add domain tests for reading an attachment with content**

Add a test under the existing attachment lifecycle test group:

```elixir
test "gets an active attachment and its raw content by note and attachment id" do
  with_storage_test_config(fn ->
    note =
      note_fixture(%{
        attachments: [
          text_attachment("standalone-read", "docs/read.txt", "stored bytes", "Readable")
        ]
      })

    assert {:ok, %Attachment{} = attachment, "stored bytes"} =
             GaoNote.get_attachment_with_content(note.id, "standalone-read")

    assert attachment.id == "standalone-read"
    assert attachment.note_id == note.id
    assert attachment.path == "./docs/read.txt"
    assert attachment.description == "Readable"
    assert attachment.mime == "text/plain"
    assert %StorageFile{} = attachment.storage_file
  end)
end
```

Also assert `{:error, :not_found}` for an unknown note, an unknown attachment, and an attachment whose note has been logically deleted.

- [ ] **Step 2: Add replacement tests**

Add tests proving:

```elixir
assert {:ok, %Attachment{} = updated} =
         GaoNote.put_attachment(
           note.id,
           "standalone-put",
           %{
             path: "./docs/renamed.txt",
             mime: "text/plain",
             description: "Renamed",
             update_content: false
           },
           actor()
         )

assert updated.id == "standalone-put"
assert updated.note_id == note.id
assert updated.storage_file_id == original.storage_file_id
assert {:ok, ^updated, "original bytes"} =
         GaoNote.get_attachment_with_content(note.id, "standalone-put")
```

Add a content-replacement case:

```elixir
assert {:ok, %Attachment{} = replaced} =
         GaoNote.put_attachment(
           note.id,
           "standalone-put",
           %{
             path: "./docs/replaced.txt",
             mime: "text/plain",
             description: "Replaced",
             update_content: true,
             content: "replacement bytes"
           },
           actor()
         )

refute replaced.storage_file_id == original.storage_file_id

assert {:ok, ^replaced, "replacement bytes"} =
         GaoNote.get_attachment_with_content(note.id, "standalone-put")
```

Run the replacement assertion inside `Oban.Testing.with_testing_mode(:manual, ...)` and assert that the old `storage_file_id` is enqueued for `StorageFilePurgeWorker`.

- [ ] **Step 3: Add validation, ownership, and rollback tests**

Cover these exact failures:

```elixir
assert {:error, {:attachment, %{code: :not_found}}} =
         GaoNote.put_attachment(note.id, "missing", valid_put_attrs(), actor())

assert {:error, {:attachment, %{code: :owned_by_another_note}}} =
         GaoNote.put_attachment(other_note.id, attachment.id, valid_put_attrs(), actor())

assert {:error, {:attachment, %{code: :retained_mime_mismatch}}} =
         GaoNote.put_attachment(
           note.id,
           attachment.id,
           Map.put(valid_put_attrs(), :mime, "application/json"),
           actor()
         )

assert {:error, {:attachment, %{code: :content_required}}} =
         GaoNote.put_attachment(
           note.id,
           attachment.id,
           Map.put(valid_put_attrs(), :update_content, true),
           actor()
         )

assert {:error, {:attachment, %{code: :content_not_allowed}}} =
         GaoNote.put_attachment(
           note.id,
           attachment.id,
           valid_put_attrs()
           |> Map.put(:update_content, false)
           |> Map.put(:content, "unexpected"),
           actor()
         )
```

Use the existing failing-storage test configuration to prove that an S3 upload
failure leaves the old attachment row and `storage_file_id` unchanged.

- [ ] **Step 4: Add deletion tests**

Add a test that creates two attachments, deletes one, and proves the other is
untouched:

```elixir
Oban.Testing.with_testing_mode(:manual, fn ->
  assert {:ok, %Attachment{id: "delete-me"} = deleted} =
           GaoNote.delete_attachment(note.id, "delete-me", actor())

  assert Repo.get(Attachment, "delete-me") == nil
  assert %Attachment{id: "keep-me"} = Repo.get(Attachment, "keep-me")

  assert_enqueued(
    worker: StorageFilePurgeWorker,
    args: %{storage_file_id: deleted.storage_file_id}
  )
end)
```

Assert missing and wrong-owner requests return explicit attachment errors and
do not delete either attachment.

- [ ] **Step 5: Implement content retrieval in `Attachments`**

Generalize the existing active attachment query and storage reader:

```elixir
def get_with_content(note_id, attachment_id) do
  with {:ok, note_id} <- cast_note_id(note_id),
       :ok <- validate_attachment_id(attachment_id),
       %Attachment{} = attachment <- get_active_by_id(note_id, attachment_id),
       {:ok, bytes} <- read_storage_file(attachment.storage_file) do
    {:ok, attachment, bytes}
  else
    nil -> {:error, :not_found}
    {:error, :invalid_note_id} -> {:error, :not_found}
    {:error, _reason} = error -> error
  end
end
```

`get_active_by_id/2` must reuse `attachment_query/0`, `active_scope/1`, and
preload the joined `storage_file`. Do not perform UTF-8 validation; this API is
binary-safe.

- [ ] **Step 6: Implement strict put-input validation**

In `Attachments`, normalize atom/string keys and require:

```elixir
%{
  id: attachment_id,
  path: path,
  mime: mime,
  description: description,
  update_content: update_content
}
```

Use `AttachmentInput.cast/1` after inserting the immutable `id`. Enforce:

```elixir
case {update_content, content_present?, content_base64_present?} do
  {false, false, false} -> :ok
  {false, _, _} -> attachment_error(attachment_id, :content_not_allowed)
  {true, true, false} -> :ok
  {true, false, true} -> :ok
  {true, false, false} -> attachment_error(attachment_id, :content_required)
  {true, true, true} -> attachment_error(attachment_id, :multiple_content_sources)
end
```

Reject absent or non-boolean `update_content`. Require full `path`, `mime`, and
`description` metadata. Do not permit a submitted `id` or `note_id` to override
the function arguments.

- [ ] **Step 7: Implement targeted replacement**

Add:

```elixir
def put(note_id, attachment_id, raw_attrs, uploaded_by)
```

The operation must:

1. Cast `note_id` and validate `attachment_id`.
2. Load the active attachment and distinguish `:not_found` from
   `:owned_by_another_note`.
3. Build a retain or replace entry with existing `build_entry/2`.
4. Stage replacement bytes before the database transaction.
5. In a transaction, lock the active note and attachment, verify the original
   attachment snapshot, and update only that row.
6. Preserve `id` and `note_id`.
7. Preserve `storage_file_id` when `update_content=false`.
8. Use the staged storage file when `update_content=true`.
9. Enqueue the old storage file for purge only after a successful row update.
10. Call `cleanup/1` if the transaction rolls back or raises.

Use the existing `Attachment.changeset/2` so canonical-path uniqueness and
database constraints remain authoritative. Do not call `reconcile/2`, because
it is a full-list operation and temporarily moves every attachment path.

- [ ] **Step 8: Implement targeted deletion**

Add:

```elixir
def delete(note_id, attachment_id)
```

Inside one `Repo.transaction/1`, lock the active note and selected attachment,
verify ownership, enqueue `StorageFilePurgeWorker` for its `storage_file_id`,
and call `Repo.delete/1`. Return `{:ok, attachment}` after unwrapping the
transaction result.

- [ ] **Step 9: Expose actor-aware context functions**

Add these functions to `GSMLG.GaoNote`:

```elixir
def get_attachment_with_content(note_id, attachment_id),
  do: Attachments.get_with_content(note_id, attachment_id)

def put_attachment(note_id, attachment_id, attrs, actor) do
  with {:ok, attachment} <-
         Attachments.put(note_id, attachment_id, attrs, actor_id(actor)) do
    log_action("update", "attachment", attachment.id, note_id, actor, %{
      "path" => attachment.path,
      "mime" => attachment.mime,
      "description" => attachment.description,
      "content_updated" => truthy_attr?(attrs, :update_content)
    })

    {:ok, attachment}
  end
end

def delete_attachment(note_id, attachment_id, actor) do
  with {:ok, attachment} <- Attachments.delete(note_id, attachment_id) do
    log_action("delete", "attachment", attachment.id, note_id, actor, %{
      "path" => attachment.path,
      "mime" => attachment.mime
    })

    {:ok, attachment}
  end
end
```

Use the context’s existing string/atom attribute normalization helper instead
of introducing `truthy_attr?/2` if an equivalent helper already exists.

- [ ] **Step 10: Add an attachment-preserving note update function**

Extract the note-and-label portion of `update_note/3` into:

```elixir
def update_note_fields(%Note{} = note, attrs, actor)
```

It must normalize only note and label inputs, lock the active note, update
title/content, replace labels only when supplied, preload the note, and log only
the fields actually changed. It must reject an `attachments` key instead of
silently accepting it.

Keep `update_note/3` unchanged for existing HTTP and LiveView aggregate callers.
The MCP dispatch will use `update_note_fields/3`.

## Task 2: Publish Minimal MCP Tool Contracts

**Files:**

- Modify: `apps/gsmlg_gao_note/test/gsmlg/gao_note/mcp/aggregate_contract_test.exs`
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/tools.ex`

- [ ] **Step 1: Replace aggregate-only tool registration assertions**

Readonly tools must be exactly:

```elixir
~w(
  gao_note.get
  gao_note.get_attachment_with_content
  gao_note.list_label_settings
  gao_note.search
)
```

Admin tools must additionally contain:

```elixir
~w(
  gao_note.create_label_setting
  gao_note.create_note
  gao_note.delete
  gao_note.delete_attachment
  gao_note.put_attachment
  gao_note.set_labels
  gao_note.update_note
)
```

Remove the new names from `@removed_tool_names` and continue asserting that old
plural/namespaced attachment tools remain absent.

- [ ] **Step 2: Replace the `update_note` aggregate schema assertion**

Assert:

```elixir
schema = tool("gao_note.update_note").input_schema

assert Map.keys(schema["properties"]) |> Enum.sort() ==
         ~w(content id labels title)

assert schema["required"] == ["id"]
refute Map.has_key?(schema["properties"], "attachments")
```

- [ ] **Step 3: Add exact schemas for standalone tools**

Assert:

```elixir
assert property_names("gao_note.get_attachment_with_content") ==
         ~w(attachment_id note_id)

assert property_names("gao_note.delete_attachment") ==
         ~w(attachment_id note_id)

assert property_names("gao_note.put_attachment") ==
         ~w(
           attachment_id
           content
           content_base64
           description
           mime
           note_id
           path
           update_content
         )
```

`note_id` and `attachment_id` are required for read/delete. Put additionally
requires `path`, `mime`, `description`, and `update_content`. Its JSON Schema
must encode the two valid content branches:

```json
[
  {
    "properties": {"update_content": {"const": false}},
    "not": {
      "anyOf": [
        {"required": ["content"]},
        {"required": ["content_base64"]}
      ]
    }
  },
  {
    "properties": {"update_content": {"const": true}},
    "oneOf": [
      {
        "required": ["content"],
        "not": {"required": ["content_base64"]}
      },
      {
        "required": ["content_base64"],
        "not": {"required": ["content"]}
      }
    ]
  }
]
```

- [ ] **Step 4: Register tool access and annotations**

Add `gao_note.get_attachment_with_content` to `@readonly_tools`. Add
`gao_note.put_attachment` and `gao_note.delete_attachment` to admin tools.

Annotations:

- `get_attachment_with_content`: read-only, non-destructive, idempotent.
- `put_attachment`: mutating, non-destructive, idempotent.
- `delete_attachment`: mutating, destructive, idempotent.

- [ ] **Step 5: Add Peri validation and JSON Schema overrides**

Add strict tool-specific schemas rather than a catch-all field union.
`put_attachment` must validate the same content matrix as the domain service.
All three schemas set `additionalProperties` to `false`.

Extend `ToolComponent.input_schema_override/1` and `schema_block/1` so
`gao_note.put_attachment` uses its custom conditional schema while read/delete
use normal field declarations.

- [ ] **Step 6: Remove attachments from MCP note updates**

Delete the attachment field from `@input_fields["gao_note.update_note"]`, update
its description, and change dispatch to:

```elixir
defp dispatch("gao_note.update_note", args, frame, _mode) do
  with {:ok, actor} <- Authorization.actor(frame),
       %{} = note <- GaoNote.get_note(Map.get(args, "id")),
       attrs <- Map.drop(args, ["id"]),
       {:ok, note} <- GaoNote.update_note_fields(note, attrs, mcp_actor(actor)) do
    audit("gao_note.update_note", actor, note.id)
    ok("Updated GaoNote: #{note.title}", %{"note" => Presenter.note(note)})
  else
    nil -> error("GaoNote not found")
    {:error, reason} -> error(reason)
  end
end
```

- [ ] **Step 7: Implement attachment dispatch**

Use the selected note access path before content reads:

```elixir
defp dispatch("gao_note.get_attachment_with_content", args, _frame, mode) do
  note_id = Map.get(args, "note_id")
  attachment_id = Map.get(args, "attachment_id")

  with %{} <- fetch_note(%{"id" => note_id}, mode),
       {:ok, attachment, bytes} <-
         GaoNote.get_attachment_with_content(note_id, attachment_id) do
    data =
      attachment
      |> Presenter.attachment()
      |> Map.put(:content_base64, Base.encode64(bytes))

    ok("Retrieved GaoNote attachment: #{attachment.id}", %{"attachment" => data})
  else
    nil -> error("GaoNote attachment not found")
    {:error, :not_found} -> error("GaoNote attachment not found")
    {:error, reason} -> error(reason)
  end
end
```

Admin put dispatch:

```elixir
with {:ok, actor} <- Authorization.actor(frame),
     {:ok, attachment} <-
       GaoNote.put_attachment(
         args["note_id"],
         args["attachment_id"],
         Map.drop(args, ["note_id", "attachment_id"]),
         mcp_actor(actor)
       ) do
  audit("gao_note.put_attachment", actor, args["note_id"])
  ok("Replaced GaoNote attachment: #{attachment.id}", %{
    "attachment" => Presenter.attachment(attachment)
  })
end
```

Admin delete dispatch follows the same pattern and returns deleted attachment
metadata without content.

- [ ] **Step 8: Add component modules**

Register:

```elixir
defmodule GSMLG.GaoNote.MCP.Tools.GetAttachmentWithContent do
  use GSMLG.GaoNote.MCP.ToolComponent,
    name: "gao_note.get_attachment_with_content"
end

defmodule GSMLG.GaoNote.MCP.Tools.PutAttachment do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.put_attachment"
end

defmodule GSMLG.GaoNote.MCP.Tools.DeleteAttachment do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.delete_attachment"
end
```

## Task 3: Cover MCP Execution and Streamable HTTP

**Files:**

- Modify: `apps/gsmlg_gao_note/test/gsmlg/gao_note/mcp_test.exs`
- Modify: `apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/gao_note_mcp_controller_test.exs`
- Modify: `apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_mcp_controller_test.exs`

- [ ] **Step 1: Update direct server registration tests**

Readonly mode must include only the new read tool. Admin mode must also include
put/delete. Continue rejecting the removed legacy tools:

```elixir
assert "gao_note.get_attachment_with_content" in readonly_names
refute "gao_note.put_attachment" in readonly_names
refute "gao_note.delete_attachment" in readonly_names

assert "gao_note.get_attachment_with_content" in admin_names
assert "gao_note.put_attachment" in admin_names
assert "gao_note.delete_attachment" in admin_names
```

- [ ] **Step 2: Prove create and update contracts**

Retain the existing create-with-attachments test. Change the update call to omit
attachments and assert the created attachment remains:

```elixir
assert %{"structuredContent" => %{"note" => updated}} =
         call_tool(
           GSMLG.GaoNote.MCP.AdminServer,
           "gao_note.update_note",
           %{
             "id" => created["id"],
             "title" => "Updated without attachment transfer"
           },
           frame
         )

assert [%{"id" => ^attachment_id}] = updated["attachments"]
```

Assert passing an `attachments` key now returns invalid parameters.

- [ ] **Step 3: Test Base64 content retrieval in both modes**

Create a note with binary bytes, then call:

```elixir
%{
  "note_id" => note.id,
  "attachment_id" => attachment.id
}
```

Assert both readonly and admin servers return:

```elixir
%{
  "attachment" => %{
    "id" => attachment.id,
    "path" => "./image.bin",
    "mime" => "application/octet-stream",
    "description" => "Binary",
    "content_base64" => Base.encode64(bytes)
  }
}
```

Refute `content` and storage backend credentials/paths.

- [ ] **Step 4: Test put and delete execution**

Through `call_tool/4`, prove:

- Metadata-only put preserves bytes.
- Content put replaces bytes.
- A content field with `update_content=false` is rejected before dispatch.
- Missing content with `update_content=true` is rejected before dispatch.
- A wrong note/attachment pair is rejected.
- Delete removes only the selected attachment.
- Put/delete require an authenticated actor.
- The expected `attachment` update/delete log has source `"mcp"`.

- [ ] **Step 5: Update admin controller discovery and calls**

Change the exact `tools/list` expectation to include all three standalone tools.
Assert `update_note` requires only `id`, and assert each new input schema matches
Task 2.

Replace the obsolete “missing aggregate attachment list” and “omitted
attachment removal” tests with authenticated put/delete calls using
`call_mcp_tool/3`.

- [ ] **Step 6: Update readonly controller discovery and content call**

Add `gao_note.get_attachment_with_content` to the expected public tool list.
Continue asserting that put/delete and every legacy attachment tool are absent.

Create an attachment fixture and call the read tool over
`POST /mcp/gao_note`; assert metadata plus exact Base64 bytes are returned.

## Task 4: Focused Verification

No command in this task should be run without explicit user permission under
the repository collaboration rules.

- [ ] **Step 1: Format only changed Elixir files**

```bash
mix format \
  apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex \
  apps/gsmlg_gao_note/lib/gsmlg/gao_note/attachments.ex \
  apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/tools.ex \
  apps/gsmlg_gao_note/test/gsmlg/gao_note_test.exs \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/mcp/aggregate_contract_test.exs \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/mcp_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/gao_note_mcp_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_mcp_controller_test.exs
```

Expected: exit status `0`.

- [ ] **Step 2: Run focused domain tests**

```bash
devenv shell -- env \
  DATABASE_URL=postgres://gsmlg_dev:gsmlg_dev@localhost:5433/gsmlg_test \
  mix test \
  apps/gsmlg_gao_note/test/gsmlg/gao_note_test.exs \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/mcp/aggregate_contract_test.exs \
  apps/gsmlg_gao_note/test/gsmlg/gao_note/mcp_test.exs
```

Expected: all tests pass.

- [ ] **Step 3: Run focused transport tests**

```bash
devenv shell -- env \
  DATABASE_URL=postgres://gsmlg_dev:gsmlg_dev@localhost:5433/gsmlg_test \
  mix test \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/gao_note_mcp_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_mcp_controller_test.exs
```

Expected: all tests pass.

- [ ] **Step 4: Compile with warnings treated as errors**

```bash
devenv shell -- mix compile --warnings-as-errors
```

Expected: compilation succeeds with no warnings.

