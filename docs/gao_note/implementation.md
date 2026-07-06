# GaoNote Implementation Plan

## 1. Goal

Implement a new note system named **GaoNote** for `gsmlg_umbrella`.

GaoNote must support:

* Notes with Markdown content.
* Tags.
* Web references.
* S3-backed assets.
* Read-only MCP access from `gsmlg_web`.
* Full CRUD MCP access from `gsmlg_admin_web`.
* Admin UI visible only under the **Content** menu in Admin Web.

The implementation should keep domain logic outside the web layers. The umbrella release already starts `gsmlg`, `gsmlg_admin_web`, and `gsmlg_web` together, so GaoNote should be implemented as a reusable domain app consumed by both web applications. 

---

## 2. Existing repo constraints

### 2.1 Domain pattern

The repo already has a `GSMLG.Content` context for Blog CRUD. Blog listing, create, update, delete, and translation workflows are implemented in the domain layer, while controllers and LiveViews call into that context.   

GaoNote should follow the same pattern: schema and business rules in a domain app, web adapters in `gsmlg_web` and `gsmlg_admin_web`.

### 2.2 Storage pattern

The repo already has `GSMLG.Storage`, a centralized S3-backed file API. It supports uploads from `Plug.Upload`, file path strings, and `{filename, binary}` tuples; it stores metadata, checksum, S3 key, file size, content type, variants, and status in `storage_files`.   

Use `GSMLG.Storage` for GaoNote assets instead of building a second S3 abstraction.

### 2.3 Admin menu placement

The Admin Web menu is currently hardcoded in `GSMLG.Component.Admin.local_app_menus/1`. The existing `"Content"` section contains Users, User Tokens, Blogs, Web Push, and Github. GaoNote should be added to this section only. 

### 2.4 Admin route protection

Admin LiveView routes are already grouped under a protected browser scope using `:browser`, `:maybe_browser_auth`, and `:ensure_authed_access`. GaoNote admin pages should be added inside that scope. 

### 2.5 Asset visibility warning

Current public file serving in `gsmlg_web` exposes active storage files under `/files/:id` without authentication, and the controller explicitly says all active files are publicly accessible. Private GaoNote assets must not rely on this endpoint until storage-level visibility or signed access is implemented.  

---

## 3. Application architecture

Create a new umbrella app:

```text
apps/gsmlg_gao_note
```

Primary public context:

```elixir
GSMLG.GaoNote
```

Recommended modules:

```text
apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex
apps/gsmlg_gao_note/lib/gsmlg/gao_note/note.ex
apps/gsmlg_gao_note/lib/gsmlg/gao_note/tag.ex
apps/gsmlg_gao_note/lib/gsmlg/gao_note/tagging.ex
apps/gsmlg_gao_note/lib/gsmlg/gao_note/reference.ex
apps/gsmlg_gao_note/lib/gsmlg/gao_note/asset.ex
apps/gsmlg_gao_note/lib/gsmlg/gao_note/presenter.ex
apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/readonly_server.ex
apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/admin_server.ex
apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/readonly_plug.ex
apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/admin_plug.ex
apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/authorization.ex
apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/tools/*.ex
apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/resources/*.ex
```

Add dependencies:

```elixir
# apps/gsmlg_gao_note/mix.exs
{:gsmlg, in_umbrella: true},
{:gsmlg_storage, in_umbrella: true},
{:backplane_mcp_protocol, "~> 1.6"}
```

Then add GaoNote to both web apps:

```elixir
# apps/gsmlg_web/mix.exs
{:gsmlg_gao_note, in_umbrella: true}

# apps/gsmlg_admin_web/mix.exs
{:gsmlg_gao_note, in_umbrella: true}
```

Preferred dependency boundary: expose thin GaoNote-owned plugs that delegate to `Backplane.McpProtocol.Server.Transport.StreamableHTTP.Plug`, so the web apps depend only on `gsmlg_gao_note`. Only add `{:backplane_mcp_protocol, "~> 1.6"}` to a web app if its router references Backplane MCP modules directly.

Do not put GaoNote directly in `GSMLG.Content` because `gsmlg_storage` already depends on `gsmlg`, and GaoNote needs to depend on storage. A separate app avoids a dependency cycle. 

---

## 4. Database design

Migrations should live under:

```text
apps/gsmlg/priv/repo/migrations
```

Existing storage migrations already use that path because `GSMLG.Repo` is owned by the core `gsmlg` app. 

### 4.1 Tables

Use these tables:

```text
gao_notes
gao_note_tags
gao_note_taggings
gao_note_references
gao_note_assets
```

### 4.2 `gao_notes`

Purpose: main note entity.

Fields:

```text
id             binary_id primary key
title          string, required
description    text, optional, defaults to ""
content        text, required, Markdown
creator        string, optional free-form creator display name, defaults to ""
created_at
updated_at
```

Indexes:

```text
index on creator
```

### 4.3 `gao_note_tags`

Purpose: normalized tag dictionary.

Fields:

```text
id          binary_id primary key
name        string, required
color       string
metadata    map, default %{}
inserted_at
updated_at
```

Indexes:

```text
unique index on lower(name)
```

Tag rules:

```text
name: display label
dedupe by case-insensitive normalized name
```

### 4.4 `gao_note_taggings`

Purpose: many-to-many note/tag relation.

Fields:

```text
note_id binary_id, references gao_notes.id, required
tag_id  binary_id, references gao_note_tags.id, required
```

Indexes:

```text
unique index on [note_id, tag_id]
index on tag_id
```

Use `on_delete: :delete_all` for both note and tag references.

### 4.5 `gao_note_references`

Purpose: web links attached to a note.

Fields:

```text
id             binary_id primary key
note_id        binary_id, references gao_notes.id, required
url            text, required
canonical_url  text
title          string
description    text
site_name      string
favicon_url    text
position       integer, default 0
metadata       map, default %{}
inserted_at
updated_at
```

Indexes:

```text
index on note_id
index on canonical_url
unique index on [note_id, canonical_url], where canonical_url is not null
```

Reference rules:

```text
url: original URL submitted by user
canonical_url: normalized URL for deduplication
metadata: optional enrichment result
```

### 4.6 `gao_note_assets`

Purpose: relation between a note and an S3-backed `storage_files` row.

Fields:

```text
id               binary_id primary key
note_id          binary_id, references gao_notes.id, required
storage_file_id  binary_id, references storage_files.id, required
role             string, default "attachment"
caption          text
alt_text         text
position         integer, default 0
metadata         map, default %{}
inserted_at
updated_at
```

Allowed asset roles:

```text
attachment | cover | inline | source
```

Indexes:

```text
index on note_id
index on storage_file_id
unique index on [note_id, storage_file_id]
```

---

## 5. Domain API

Implement public functions in `GSMLG.GaoNote`.

### 5.1 Read API

```elixir
list_notes(opts \\ [])
search_notes(query, opts \\ [])
get_note!(id)
get_note(id)
list_tags(opts \\ [])
get_tag(id)
get_tag!(id)
list_references(note_or_id)
list_assets(note_or_id)
```

Supported `list_notes/1` options:

```text
:tag
:search
:creator
:limit
:offset
:order_by
```

Default ordering:

```text
updated_at desc
```

### 5.2 Write API

```elixir
create_note(attrs, actor)
update_note(note, attrs, actor)
delete_note(note, actor)

create_tag(attrs)
update_tag(tag, attrs)
delete_tag(tag)
replace_tags(note, tag_names, actor)

add_reference(note, attrs, actor)
update_reference(reference, attrs, actor)
remove_reference(reference, actor)

attach_asset(note, storage_file_id, attrs, actor)
upload_asset(note, upload_input, attrs, actor)
update_asset(asset, attrs, actor)
detach_asset(asset, actor)
```

All write functions should return:

```elixir
{:ok, result} | {:error, changeset_or_reason}
```

Use `Ecto.Multi` for operations that touch more than one table, especially:

```text
create note + tags + references
update note + replace tags
upload asset + create gao_note_assets row
delete note + dependent rows
```

## 6. Schemas and changesets

### 6.1 Note changeset

Validation:

```text
title required
description optional
content required and interpreted as Markdown
creator optional; MCP agents should fill it with the note-writing agent name
```

### 6.2 Tag changeset

Validation:

```text
name required
```

Tag normalization:

```text
trim name
collapse spaces
dedupe by case-insensitive normalized name
```

### 6.3 Reference changeset

Validation:

```text
url required
url scheme must be http or https
position integer >= 0
```

Normalization:

```text
canonical_url = normalized URL without tracking query params
```

Suggested tracking params to remove:

```text
utm_source
utm_medium
utm_campaign
utm_term
utm_content
fbclid
gclid
mc_cid
mc_eid
```

### 6.4 Asset changeset

Validation:

```text
note_id required
storage_file_id required
role in ["attachment", "cover", "inline", "source"]
position integer >= 0
```

---

## 7. Asset handling

### 7.1 Upload convention

For GaoNote assets, call:

```elixir
GSMLG.Storage.upload(input, "gao_note", "asset",
  uploaded_by: actor.id,
  metadata: %{
    "note_id" => note.id,
    "original_name" => filename
  }
)
```

The admin storage UI already demonstrates the correct pattern: LiveView consumes uploaded entries and calls `Storage.upload(path, tenant, type, uploaded_by: ..., metadata: ...)`. 

### 7.2 Asset URL rule

Until `storage_files` has visibility or signed URLs, use this rule:

```text
Only assets whose underlying storage file metadata marks them public may expose /files/:id.
```

Preferred storage enhancement:

```text
add storage_files.visibility: private | public
add storage_files.access_scope: note | general | system
```

Alternative phase-1 workaround:

```text
store %{"visibility" => "private"} in storage_files.metadata
enforce access only through GaoNote.Asset policy
do not link private assets to /files/:id
```

---

## 8. Admin Web implementation

### 8.1 Routes

Add routes inside the authenticated Admin Web browser scope:

```elixir
live("/gao_notes/notes", GaoNoteLive.Index, :index)
live("/gao_notes/notes/new", GaoNoteLive.Index, :new)
live("/gao_notes/notes/:id", GaoNoteLive.Index, :show)
live("/gao_notes/notes/:id/edit", GaoNoteLive.Index, :edit)
live("/gao_notes/notes/:id/references", GaoNoteLive.ReferenceLive.Index, :index)
live("/gao_notes/notes/:id/assets", GaoNoteLive.AssetLive.Index, :index)
live("/gao_notes/references", GaoNoteLive.ReferenceLive.Index, :all)
live("/gao_notes/assets", GaoNoteLive.AssetLive.Index, :all)
live("/gao_notes/tags", GaoNoteLive.TagLive.Index, :index)
```

Legacy `/gao_notes` and `/gao_notes/new` may redirect to the note-management routes. The note list should link to `/gao_notes/notes`, and the list page can expose a create action for `/gao_notes/notes/new`; the new-note form should not have its own left-menu entry. The GaoNote menu should also expose global reference and asset index pages at `/gao_notes/references` and `/gao_notes/assets`.

### 8.2 Menu

Add GaoNote under the existing Content section:

```elixir
%{id: "gao_note_list", label: "Note List", path: "/gao_notes/notes"}
%{id: "gao_note_tags", label: "Tags", path: "/gao_notes/tags"}
```

Target files:

```text
apps/gsmlg_admin_web/lib/gsmlg/admin_web/admin_menu.ex
apps/gsmlg_component/lib/gsmlg/component/admin.ex
```

The left navigation is defined in `GSMLG.AdminWeb.AdminMenu`. The top app menu in `GSMLG.Component.Admin.local_app_menus/1` should link GaoNote to `/gao_notes/notes`.

### 8.3 LiveViews

Create:

```text
apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/index.ex
apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/tag_live/index.ex
apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/reference_live/index.ex
apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/asset_live/index.ex
```

`GaoNoteLive.Index` responsibilities:

```text
:index  list/search/filter notes
:new    create note
:show   view note detail
:edit   edit note
```

Load database-backed note list and tag option data with `assign_async/3`, not direct synchronous assigns. Tests that assert loaded note or tag data should call `render_async/1`.

The note form should use `dm_multi_select/1` for tag selection. `phoenix_duskmoon` currently provides `dm_multi_select/1` for existing multi-value options, but it does not provide a creatable "type a new option and add it" control. Track the upstream request at https://github.com/duskmoon-dev/phoenix-duskmoon-ui/issues/38. Until that lands, GaoNote may add a small LiveView/JS wrapper around `dm_multi_select/1` plus an add-option input.

Tag LiveView responsibilities:

```text
list tags
create tag
edit tag name/color
delete tag
```

Load the tag list with `assign_async/3` and render an explicit loading state.

Reference LiveView responsibilities:

```text
list all references
list references
add reference
edit reference metadata
delete reference
reorder references
```

Asset LiveView responsibilities:

```text
list all assets
list assets
upload asset
attach existing storage file
edit caption/alt/role
detach asset
reorder assets
```

### 8.4 Admin UI filters

Index filters:

```text
search
tag
```

Default index display:

```text
title
description
creator
created_at
updated_at
actions
```

---

## 9. Public Web implementation

No public HTML pages are required for phase 1.

`gsmlg_web` should expose GaoNote only through read-only MCP:

```text
POST /mcp/gao_note
GET  /mcp/gao_note
```

Optional future public pages can be added later:

```text
GET /notes
GET /notes/:id
```

---

## 10. MCP implementation

Use [`backplane_mcp_protocol`][4] as the MCP protocol and transport implementation. Backplane MCP Protocol provides the protocol-level server implementation, Streamable HTTP transport, Phoenix/Plug integration, tool/resource dispatch, schemas, and MCP response framing. GaoNote code should implement only the application layer: note tools, resource loaders, authorization policy, presentation, auditing, and domain calls.

Do **not** hand-roll JSON-RPC parsing, `initialize`, `tools/list`, `tools/call`, `resources/list`, `resources/read`, Streamable HTTP session behavior, or MCP response envelopes. Those belong to Backplane MCP Protocol.

Follow the Backplane MCP Protocol application pattern: define GaoNote servers with `use Backplane.McpProtocol.Server`, define tools/resources as Backplane MCP components, and mount them through the Backplane Streamable HTTP Plug, either directly or through GaoNote-owned wrapper plugs. ([Backplane MCP Protocol][5])

### 10.1 Target transport

Use Backplane Streamable HTTP for both web apps.

MCP uses JSON-RPC messages and defines stdio plus Streamable HTTP as standard transports. Streamable HTTP requires a single endpoint path that supports POST and GET. ([Model Context Protocol][1])

Endpoints:

```text
gsmlg_web:
  POST /mcp/gao_note
  GET  /mcp/gao_note

gsmlg_admin_web:
  POST /mcp/gao_note
  GET  /mcp/gao_note
```

### 10.2 Shared MCP modules

Use two Backplane MCP servers with shared application components:

```text
GSMLG.GaoNote.MCP.ReadOnlyServer
GSMLG.GaoNote.MCP.AdminServer
GSMLG.GaoNote.MCP.ReadOnlyPlug
GSMLG.GaoNote.MCP.AdminPlug
GSMLG.GaoNote.MCP.Authorization
GSMLG.GaoNote.MCP.Presenter

GSMLG.GaoNote.MCP.Tools.Search
GSMLG.GaoNote.MCP.Tools.Get
GSMLG.GaoNote.MCP.Tools.ListTags
GSMLG.GaoNote.MCP.Tools.ListReferences
GSMLG.GaoNote.MCP.Tools.ListAssets
GSMLG.GaoNote.MCP.Tools.Create
GSMLG.GaoNote.MCP.Tools.CreateTag
GSMLG.GaoNote.MCP.Tools.Update
GSMLG.GaoNote.MCP.Tools.Delete
GSMLG.GaoNote.MCP.Tools.SetTags
GSMLG.GaoNote.MCP.Tools.References.*
GSMLG.GaoNote.MCP.Tools.Assets.*

GSMLG.GaoNote.MCP.Resources.Note
GSMLG.GaoNote.MCP.Resources.Tag
GSMLG.GaoNote.MCP.Resources.Asset
```

Server split:

```elixir
GSMLG.GaoNote.MCP.ReadOnlyServer
# registers only read-only tools/resources

GSMLG.GaoNote.MCP.AdminServer
# registers read and write tools/resources
```

Adapters:

```text
GSMLG.Web.Router
GSMLG.AdminWeb.Router
```

Supervision:

```text
GSMLG.Web.Application starts GSMLG.GaoNote.MCP.ReadOnlyServer before the public Endpoint
GSMLG.AdminWeb.Application starts GSMLG.GaoNote.MCP.AdminServer before the admin Endpoint
```

The server modules and tool/resource components still live in `gsmlg_gao_note`; the web apps supervise the concrete Backplane MCP server process they expose so each endpoint owns its MCP runtime.

Routing should forward to GaoNote-owned plugs:

```elixir
forward("/mcp/gao_note", GSMLG.GaoNote.MCP.ReadOnlyPlug)
```

Those plugs should delegate to `Backplane.McpProtocol.Server.Transport.StreamableHTTP.Plug` with the appropriate server module. Admin Web forwards the same path to `GSMLG.GaoNote.MCP.AdminPlug` inside the dedicated authenticated MCP pipeline.

### 10.3 Backplane-owned protocol methods

Backplane MCP Protocol must handle MCP protocol methods, including `initialize`, `tools/list`, `tools/call`, `resources/list`, and `resources/read`.

GaoNote modules register Backplane MCP components for tools and resources. They should define input schemas, execute domain calls, and return Backplane MCP responses. They should not match directly on JSON-RPC method names.

MCP resources are URI-identified data exposed by servers, and clients use `resources/list` and `resources/read` to discover and retrieve them. ([Model Context Protocol][2])

MCP tools are model-callable functions with names, descriptions, and JSON schemas; clients discover them with `tools/list` and invoke them with `tools/call`. ([Model Context Protocol][3])

### 10.4 Resource URIs

Use a custom scheme:

```text
gaonote://notes/{id}
gaonote://notes/{id}/metadata
gaonote://notes/{id}/references
gaonote://notes/{id}/assets
gaonote://tags/{id}
gaonote://assets/{asset_id}
```

Resource read behavior:

```text
readonly mode:
  read-only note resources

admin mode:
  all notes visible to authenticated admin actor
```

### 10.5 Read-only MCP tools for `gsmlg_web`

Expose only:

```text
gao_note.search
gao_note.get
gao_note.list_tags
gao_note.list_references
gao_note.list_assets
```

Do not expose create, update, delete, upload, attach, or detach in `gsmlg_web`.

### 10.6 Admin MCP tools for `gsmlg_admin_web`

Expose:

```text
gao_note.search
gao_note.get
gao_note.create
gao_note.create_tag
gao_note.update
gao_note.delete
gao_note.set_tags

gao_note.references.add
gao_note.references.update
gao_note.references.remove

gao_note.assets.attach_existing
gao_note.assets.upload_base64
gao_note.assets.update
gao_note.assets.detach
```

For `gao_note.create`, `creator` is a free-form display name. Agents writing notes through MCP should set it to their agent name; callers may omit it to leave Creator empty.

`gao_note.set_tags` accepts an array of tag names. Missing tags are created automatically, and `gao_note.create_tag` is available when a client wants to create a tag explicitly before assigning it.

`upload_base64` should have a strict size cap for MCP usage. Large files should go through the Admin LiveView uploader or a dedicated authenticated upload endpoint.

Suggested initial cap:

```text
5 MB base64 payload
```

### 10.7 MCP output shape

Every Backplane MCP tool should return both human-readable text and structured content through Backplane response helpers.

Example shape:

```json
{
  "content": [
    {
      "type": "text",
      "text": "Created GaoNote: My Note"
    }
  ],
  "structuredContent": {
    "note": {
      "id": "...",
      "title": "My Note",
      "description": "Short description",
      "content": "## Markdown content"
    }
  },
  "isError": false
}
```

The MCP tools spec supports structured content and recommends pairing it with serialized text for backward compatibility. ([Model Context Protocol][3]) Use Backplane response helpers rather than building this map manually.

---

## 11. MCP security

### 11.1 Public MCP

`gsmlg_web` MCP is read-only and may be unauthenticated, but it must enforce:

```text
read-only tools only
asset URLs only when storage metadata marks the file public
rate limiting
Origin validation
```

### 11.2 Admin MCP

Admin MCP must require bearer-token auth.

Current `GSMLG.AdminWeb.Router` has `Guardian.Plug.VerifyHeader` commented out in the `:maybe_api_auth` pipeline, so create a dedicated MCP admin pipeline instead of reusing the current loose API pipeline. 

Add:

```elixir
pipeline :mcp_admin_api do
  plug(:accepts, ["json"])

  plug(Guardian.Plug.Pipeline,
    module: GSMLG.AdminWeb.Guardian,
    error_handler: GSMLG.AdminWeb.Guardian.ApiAuthErrorHandler
  )

  plug(Guardian.Plug.VerifyHeader, scheme: "Bearer")
  plug(Guardian.Plug.LoadResource)
  plug(Guardian.Plug.EnsureAuthenticated, claims: %{"typ" => "access"})
  plug(GSMLG.AdminWeb.Plugs.VerifyMCPOrigin)
end
```

The authenticated actor must be passed into Backplane MCP execution context/frame metadata so admin tool components can enforce actor presence and write audit logs.

MCP Streamable HTTP servers must validate `Origin`, should implement proper authentication, and should bind local servers to localhost when running locally. ([Model Context Protocol][1])

### 11.3 Tool safety

For admin MCP mutating tools:

```text
validate all input
enforce actor presence
log actor, tool name, note id, request id
rate limit writes
sanitize returned content
return structured errors
```

The MCP tools spec also requires tool input validation, access controls, rate limiting, and output sanitization on servers. ([Model Context Protocol][3]) Prefer Backplane component schemas for input validation; keep GaoNote authorization checks in `GSMLG.GaoNote.MCP.Authorization`.

---

## 12. File changes

### 12.1 New app

```text
apps/gsmlg_gao_note/mix.exs
apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex
apps/gsmlg_gao_note/lib/gsmlg/gao_note/note.ex
apps/gsmlg_gao_note/lib/gsmlg/gao_note/tag.ex
apps/gsmlg_gao_note/lib/gsmlg/gao_note/tagging.ex
apps/gsmlg_gao_note/lib/gsmlg/gao_note/reference.ex
apps/gsmlg_gao_note/lib/gsmlg/gao_note/asset.ex
apps/gsmlg_gao_note/lib/gsmlg/gao_note/presenter.ex
apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/readonly_server.ex
apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/admin_server.ex
apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/readonly_plug.ex
apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/admin_plug.ex
apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/authorization.ex
apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/tools/*.ex
apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/resources/*.ex
```

### 12.2 New migrations

```text
apps/gsmlg/priv/repo/migrations/*_create_gao_notes.exs
apps/gsmlg/priv/repo/migrations/*_create_gao_note_tags.exs
apps/gsmlg/priv/repo/migrations/*_create_gao_note_taggings.exs
apps/gsmlg/priv/repo/migrations/*_create_gao_note_references.exs
apps/gsmlg/priv/repo/migrations/*_create_gao_note_assets.exs
```

### 12.3 Admin Web

```text
apps/gsmlg_admin_web/mix.exs
apps/gsmlg_admin_web/lib/gsmlg/admin_web/router.ex
apps/gsmlg_admin_web/lib/gsmlg/admin_web/plugs/verify_mcp_origin.ex
apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/index.ex
apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/reference_live/index.ex
apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/gao_note_live/asset_live/index.ex
```

### 12.4 Public Web

```text
apps/gsmlg_web/mix.exs
apps/gsmlg_web/lib/gsmlg/web/router.ex
apps/gsmlg_web/lib/gsmlg/web/plugs/verify_mcp_origin.ex
```

### 12.5 Component menu

```text
apps/gsmlg_component/lib/gsmlg/component/admin.ex
```

---

## 13. Tests

### 13.1 Domain tests

Create:

```text
apps/gsmlg_gao_note/test/gsmlg/gao_note_test.exs
```

Cover:

```text
create note
update note
delete note
note field validation
tag normalization
tag replacement
reference validation
reference dedupe
asset attach
asset detach
```

### 13.2 Admin LiveView tests

Cover:

```text
admin can list notes
admin can create note
admin can edit note
admin can delete note
admin can open the global references page from /gao_notes/references
admin can open the global assets page from /gao_notes/assets
admin can add/remove references
admin can upload/attach/detach assets
admin can manage tags from /gao_notes/tags
non-authenticated user cannot access /gao_notes/notes
```

### 13.3 MCP tests

Do not unit-test Backplane protocol internals. Test GaoNote Backplane server/component registration, authorization policy, domain behavior, and router integration through the Streamable HTTP endpoint.

Public MCP:

```text
Backplane read-only server registers only read-only tools/resources
POST /mcp/gao_note handles initialize through Backplane
tools/list contains read-only tools only
tools/call gao_note.search returns notes without publishing metadata
tools/call gao_note.get reads by id
resources/read returns note content by id
mutating tool names are unavailable
```

Admin MCP:

```text
requires Authorization bearer token
Backplane admin server registers CRUD tools/resources
tools/list contains CRUD tools
create/update/delete work
create_tag works
set_tags works
HTTP tools/call accepts set_tags with existing and new tag names
add/remove reference works
attach/detach asset works
invalid input returns Backplane validation failure or tool isError
```

### 13.4 Storage safety tests

Cover:

```text
asset URL is exposed only when storage visibility metadata allows it
deleted storage file is not returned as active asset
```

---

## 14. Implementation phases

### Phase 1 — Domain and migrations

Deliver:

```text
gsmlg_gao_note app
schemas
migrations
context API
domain tests
```

Exit criteria:

```text
mix test apps/gsmlg_gao_note passes
notes/tags/references/assets can be created through context API
```

### Phase 2 — Admin UI

Deliver:

```text
Admin routes
Admin menu item under Content
LiveView index/new/show/edit
Tag management
Reference management
Asset management
```

Exit criteria:

```text
authenticated admin can manage GaoNote notes from /gao_notes/notes
authenticated admin can manage GaoNote tags from /gao_notes/tags
GaoNote appears only under Content menu in Admin Web
```

### Phase 3 — Asset integration

Deliver:

```text
asset upload via GSMLG.Storage
asset attach/detach
asset visibility policy
```

Exit criteria:

```text
assets are backed by storage_files
private asset URLs are not leaked
```

### Phase 4 — Public read-only MCP

Deliver:

```text
GSMLG.GaoNote.MCP.ReadOnlyServer
GSMLG.GaoNote.MCP.ReadOnlyPlug
read-only Backplane tool components
read-only Backplane resource components
gsmlg_web route mount
```

Exit criteria:

```text
public Backplane MCP endpoint can search/read notes
public MCP cannot mutate data
```

### Phase 5 — Admin MCP

Deliver:

```text
GSMLG.GaoNote.MCP.AdminServer
GSMLG.GaoNote.MCP.AdminPlug
authenticated MCP pipeline
CRUD tools
explicit tag creation tool
reference tools
asset tools
audit logs
```

Exit criteria:

```text
admin Backplane MCP endpoint supports full GaoNote CRUD
admin MCP requires bearer auth
mutating calls are audited
```

### Phase 6 — Hardening

Deliver:

```text
Origin allowlist
rate limiting
structured audit logs
optional signed asset URLs
optional storage_files.visibility migration
```

Exit criteria:

```text
MCP endpoints are safe for production exposure
asset URLs have enforceable access rules
```

---

## 15. Acceptance criteria

GaoNote is complete when:

```text
1. A new app apps/gsmlg_gao_note exists.
2. Notes support title, description, creator, content, tags, references, and assets.
3. Assets are S3-backed through GSMLG.Storage.
4. Admin note UI is available at /gao_notes/notes; tag, reference, and asset index UIs are available at /gao_notes/tags, /gao_notes/references, and /gao_notes/assets.
5. GaoNote appears under Admin Web → Content only.
6. gsmlg_web exposes read-only MCP only through a Backplane Streamable HTTP endpoint.
7. gsmlg_admin_web exposes authenticated full CRUD MCP through a Backplane Streamable HTTP endpoint.
8. Read-only MCP cannot mutate notes.
9. Admin MCP cannot be used without bearer-token auth.
10. Tests cover domain, admin UI, MCP, and storage visibility behavior.
11. GaoNote does not implement a custom MCP protocol dispatcher; protocol and transport are delegated to `backplane_mcp_protocol`.
```

---

## 16. Recommended first commit breakdown

```text
feat(gao_note): add domain app and schemas
feat(gao_note): add notes context CRUD
feat(gao_note): add tags and references
feat(gao_note): add storage-backed assets
feat(gao_note): add Backplane MCP servers and components
feat(admin): add GaoNote LiveView management
feat(admin): add GaoNote to Content menu
feat(web): mount read-only GaoNote MCP endpoint
feat(admin): mount authenticated GaoNote MCP endpoint
test(gao_note): cover domain and MCP behavior
```

Final architectural decision: keep GaoNote as a separate umbrella app with `GSMLG.GaoNote` as the context boundary, and use `backplane_mcp_protocol` for MCP protocol and transport. This keeps the storage dependency clean, keeps web adapters thin, and lets both MCP surfaces share one Backplane-based application implementation with different authorization modes.

[1]: https://modelcontextprotocol.io/specification/2025-06-18/basic/transports "Transports - Model Context Protocol"
[2]: https://modelcontextprotocol.io/specification/2025-06-18/server/resources "Resources - Model Context Protocol"
[3]: https://modelcontextprotocol.io/specification/2025-06-18/server/tools "Tools - Model Context Protocol"
[4]: https://hex.pm/packages/backplane_mcp_protocol "backplane_mcp_protocol on Hex"
[5]: https://github.com/gsmlg-opt/backplane "Backplane MCP Protocol on GitHub"
