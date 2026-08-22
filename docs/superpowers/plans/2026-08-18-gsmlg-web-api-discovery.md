# GSMLG Web API Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove dead REST and public MCP routes from `gsmlg_web`, publish a complete OpenAPI description of its 17 supported business operations, and expose that description through the RFC 9727 API catalog.

**Architecture:** `GSMLG.Web.ApiSpec` owns one explicit OpenAPI 3.0.3 document assembled from focused schema and operation modules; OpenApiSpex renders it but never validates live requests. A minimal controller serves an RFC 9727 Linkset at `/.well-known/api-catalog`, while an exact router/spec comparison prevents documentation drift.

**Tech Stack:** Elixir 1.18, Phoenix 1.8, OpenApiSpex 3.22, Guardian, Jason, ExUnit, RFC 9727 Linkset JSON.

---

## Scope and Execution Rules

- Implement only the approved design in
  `docs/superpowers/specs/2026-08-18-gsmlg-web-api-discovery-design.md`.
- Work only in `apps/gsmlg_web`, `mix.lock`, and the approved design/plan
  documents. Do not modify `gsmlg_admin_web` or `gsmlg_gao_note`.
- Preserve all 17 surviving business operations exactly as they behave now.
- Do not add OpenApiSpex casting or validation plugs.
- Do not add Swagger UI, browser documentation, MCP exposure, deployment,
  release, push, or pull-request work.
- Run only the focused `gsmlg_web` tests named by each task. If an unrelated
  test or compilation warning outside scope fails, record it and stop instead
  of repairing it.
- Use test-first red-green-refactor steps. Do not alter a failing test merely
  to match an implementation.
- The user has not authorized commits. Stop at each checkpoint with the
  suggested conventional commit message; commit only after explicit approval.
- If execution uses a worktree, create it under
  `.trees/gsmlg-web-api-discovery` on branch
  `codex/gsmlg-web-api-discovery`.

## File Map

### Route cleanup

- `apps/gsmlg_web/lib/gsmlg/web/router.ex` — remove seven dead REST routes and
  the public MCP pipeline/route; add discovery routes later.
- `apps/gsmlg_web/lib/gsmlg/web/application.ex` — stop supervising the
  read-only MCP server.
- `apps/gsmlg_web/lib/gsmlg/web/plugs/verify_mcp_origin.ex` — delete the
  web-only MCP origin plug.
- `apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_mcp_controller_test.exs`
  — delete the public MCP transport tests.
- `apps/gsmlg_web/test/gsmlg_web/api_route_surface_test.exs` — lock the removed
  and surviving route boundary.

### OpenAPI ownership

- `apps/gsmlg_web/mix.exs` and `mix.lock` — add OpenApiSpex.
- `apps/gsmlg_web/lib/gsmlg/web/api_spec.ex` — assemble the root OpenAPI
  document and components.
- `apps/gsmlg_web/lib/gsmlg/web/open_api/operation.ex` — small map builders for
  parameters, responses, request bodies, references, and security.
- `apps/gsmlg_web/lib/gsmlg/web/open_api/schemas.ex` — reusable component
  schemas matching runtime JSON.
- `apps/gsmlg_web/lib/gsmlg/web/open_api/operations.ex` — merge the exact path
  inventories from focused operation modules.
- `apps/gsmlg_web/lib/gsmlg/web/open_api/blog_operations.ex` — blog-list
  operation.
- `apps/gsmlg_web/lib/gsmlg/web/open_api/gao_note_operations.ex` — seven
  GaoNote operations.
- `apps/gsmlg_web/lib/gsmlg/web/open_api/toolbox_operations.ex` — five toolbox
  operations.
- `apps/gsmlg_web/lib/gsmlg/web/open_api/web_push_operations.ex` — three
  WebPush operations.
- `apps/gsmlg_web/lib/gsmlg/web/open_api/proxy_rules_operations.ex` — proxy-rule
  artifact operation.

### Discovery and contract tests

- `apps/gsmlg_web/lib/gsmlg/web/controllers/api_catalog_controller.ex` — RFC
  9727 GET/HEAD representation and Link header.
- `apps/gsmlg_web/test/gsmlg_web/controllers/open_api_controller_test.exs` —
  rendered OpenAPI endpoint contract.
- `apps/gsmlg_web/test/gsmlg_web/controllers/api_catalog_controller_test.exs`
  — RFC catalog contract.
- `apps/gsmlg_web/test/gsmlg_web/open_api_spec_test.exs` — components,
  operations, auth, and exact router/spec drift checks.

## Suggested Checkpoints

These messages identify independently reviewable states. They are not
authorization to commit.

1. `refactor(web): remove unsupported public routes`
2. `feat(web): publish OpenAPI foundation`
3. `feat(web): describe public API schemas`
4. `feat(web): describe blog and GaoNote APIs`
5. `feat(web): describe toolbox and service APIs`
6. `feat(web): add RFC API catalog discovery`
7. `test(web): enforce API documentation parity`

### Task 1: Remove Dead REST Routes and Public MCP Exposure

**Files:**

- Create: `apps/gsmlg_web/test/gsmlg_web/api_route_surface_test.exs`
- Modify: `apps/gsmlg_web/lib/gsmlg/web/router.ex`
- Modify: `apps/gsmlg_web/lib/gsmlg/web/application.ex`
- Delete: `apps/gsmlg_web/lib/gsmlg/web/plugs/verify_mcp_origin.ex`
- Delete: `apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_mcp_controller_test.exs`

- [ ] **Step 1: Write the failing route-boundary tests**

Create `apps/gsmlg_web/test/gsmlg_web/api_route_surface_test.exs`:

```elixir
defmodule GSMLG.Web.ApiRouteSurfaceTest do
  use GSMLG.Web.ConnCase, async: false

  alias GSMLG.Web.Router

  @removed_routes MapSet.new([
                    {:post, "/api/sign_in"},
                    {:post, "/api/sign_up"},
                    {:delete, "/api/sign_out"},
                    {:get, "/api/blogs/:id"},
                    {:post, "/api/blogs"},
                    {:put, "/api/blogs/:id"},
                    {:delete, "/api/blogs/:id"}
                  ])

  test "dead REST and public MCP routes are absent" do
    routes = route_pairs()

    assert MapSet.disjoint?(routes, @removed_routes)
    refute Enum.any?(routes, fn {_verb, path} -> String.starts_with?(path, "/mcp") end)
  end

  test "removed REST requests use the JSON API 404 fallback", %{conn: conn} do
    requests = [
      {:post, "/api/sign_in", %{}},
      {:post, "/api/sign_up", %{}},
      {:delete, "/api/sign_out", %{}},
      {:get, "/api/blogs/dead-route", nil},
      {:post, "/api/blogs", %{}},
      {:put, "/api/blogs/dead-route", %{}},
      {:delete, "/api/blogs/dead-route", %{}}
    ]

    for {method, path, params} <- requests do
      response =
        conn
        |> recycle()
        |> dispatch(method, path, params)
        |> json_response(404)

      assert response == %{"errors" => %{"detail" => "Not Found"}}
    end
  end

  test "the public web supervisor has no read-only MCP child" do
    children = Supervisor.which_children(GSMLG.Web.Supervisor)

    refute Enum.any?(children, fn {id, _pid, _type, _modules} ->
             id == GSMLG.GaoNote.MCP.ReadOnlyServer
           end)
  end

  defp route_pairs do
    Router.__routes__()
    |> Enum.map(&{&1.verb, &1.path})
    |> MapSet.new()
  end

  defp dispatch(conn, :get, path, nil), do: get(conn, path)
  defp dispatch(conn, :post, path, params), do: post(conn, path, params)
  defp dispatch(conn, :put, path, params), do: put(conn, path, params)
  defp dispatch(conn, :delete, path, params), do: delete(conn, path, params)
end
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
mix test apps/gsmlg_web/test/gsmlg_web/api_route_surface_test.exs
```

Expected: failures show the seven routes, `/mcp/gao_note`, and the read-only
MCP supervisor child are still present.

- [ ] **Step 3: Remove the dead router entries**

In the optional-auth `/api` scope, remove:

```elixir
post("/sign_in", AuthController, :sign_in)
post("/sign_up", AuthController, :sign_up)
get("/blogs/:id", BlogController, :show)
```

Delete the complete authenticated scope whose only entries are:

```elixir
delete("/sign_out", AuthController, :sign_out)
post("/blogs", BlogController, :create)
put("/blogs/:id", BlogController, :update)
delete("/blogs/:id", BlogController, :delete)
```

Do not alter `/api/blogs`, browser `/blogs/:slug`, OAuth browser routes, or
magic-link browser routes.

- [ ] **Step 4: Remove public MCP wiring**

Delete the `:mcp_public_api` pipeline and `/mcp` scope from
`GSMLG.Web.Router`. In `GSMLG.Web.Application`, change the children to:

```elixir
children = [
  GSMLG.Web.Telemetry,
  GSMLG.Web.Endpoint
]
```

Delete:

```text
apps/gsmlg_web/lib/gsmlg/web/plugs/verify_mcp_origin.ex
apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_mcp_controller_test.exs
```

Do not edit any `gsmlg_admin_web` or `gsmlg_gao_note` file.

- [ ] **Step 5: Run the focused route tests and verify GREEN**

Run:

```bash
mix test \
  apps/gsmlg_web/test/gsmlg_web/api_route_surface_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/api_error_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/blog_controller_test.exs
mix phx.routes GSMLG.Web.Router
mix phx.routes GSMLG.AdminWeb.Router | rg '/mcp/gao_note'
```

Expected: focused tests pass; the public router lists no `/mcp` or removed
route; the admin router still lists `/mcp/gao_note`.

- [ ] **Step 6: Stop at checkpoint 1**

Review `git diff --check` and the scoped diff. Suggested commit if explicitly
authorized: `refactor(web): remove unsupported public routes`.

### Task 2: Add the Passive OpenAPI Foundation

**Files:**

- Modify: `apps/gsmlg_web/mix.exs`
- Modify: `mix.lock`
- Modify: `apps/gsmlg_web/lib/gsmlg/web/router.ex`
- Create: `apps/gsmlg_web/lib/gsmlg/web/api_spec.ex`
- Create: `apps/gsmlg_web/lib/gsmlg/web/open_api/operation.ex`
- Create: `apps/gsmlg_web/lib/gsmlg/web/open_api/operations.ex`
- Create: `apps/gsmlg_web/lib/gsmlg/web/open_api/schemas.ex`
- Create: `apps/gsmlg_web/test/gsmlg_web/controllers/open_api_controller_test.exs`

- [ ] **Step 1: Write the failing OpenAPI endpoint test**

Create
`apps/gsmlg_web/test/gsmlg_web/controllers/open_api_controller_test.exs`:

```elixir
defmodule GSMLG.Web.OpenApiControllerTest do
  use GSMLG.Web.ConnCase, async: true

  test "publishes the OpenAPI document as JSON", %{conn: conn} do
    conn = get(conn, "/api/openapi.json")

    assert [content_type] = get_resp_header(conn, "content-type")
    assert String.starts_with?(content_type, "application/json")

    document = json_response(conn, 200)
    assert document["openapi"] == "3.0.3"
    assert document["info"]["title"] == "GSMLG Web API"
    assert document["paths"]["/api/openapi.json"]["get"]["operationId"] ==
             "getOpenApiDocument"
  end
end
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
mix test apps/gsmlg_web/test/gsmlg_web/controllers/open_api_controller_test.exs
```

Expected: `404` because `/api/openapi.json` is not registered.

- [ ] **Step 3: Add OpenApiSpex to `gsmlg_web`**

Add this dependency to `apps/gsmlg_web/mix.exs`:

```elixir
{:open_api_spex, "~> 3.22"},
```

Run:

```bash
mix deps.get
```

Expected: OpenApiSpex is added to `mix.lock` without changing unrelated
dependency declarations.

- [ ] **Step 4: Add reusable operation builders**

Create `apps/gsmlg_web/lib/gsmlg/web/open_api/operation.ex`:

```elixir
defmodule GSMLG.Web.OpenApi.Operation do
  @moduledoc false

  @anonymous_or_bearer [%{}, %{"bearerAuth" => []}]
  @bearer [%{"bearerAuth" => []}]

  def anonymous_or_bearer, do: @anonymous_or_bearer
  def bearer, do: @bearer

  def ref(name), do: %{"$ref" => "#/components/schemas/#{name}"}

  def parameter(name, location, schema, description, required \\ false) do
    %{
      "name" => name,
      "in" => location,
      "required" => required or location == "path",
      "description" => description,
      "schema" => schema
    }
  end

  def json_response(description, schema_name) do
    response(description, "application/json", ref(schema_name))
  end

  def response(description) do
    %{"description" => description}
  end

  def response(description, media_type, schema) do
    %{
      "description" => description,
      "content" => %{media_type => %{"schema" => schema}}
    }
  end

  def request_body(schema_name, description) do
    %{
      "description" => description,
      "required" => true,
      "content" => %{"application/json" => %{"schema" => ref(schema_name)}}
    }
  end

  def operation(operation_id, tag, summary, responses, opts \\ []) do
    %{
      "operationId" => operation_id,
      "tags" => [tag],
      "summary" => summary,
      "parameters" => Keyword.get(opts, :parameters, []),
      "responses" => responses,
      "security" => Keyword.get(opts, :security, [])
    }
    |> maybe_put("description", Keyword.get(opts, :description))
    |> maybe_put("requestBody", Keyword.get(opts, :request_body))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
```

- [ ] **Step 5: Add the initial component and operation modules**

Create `apps/gsmlg_web/lib/gsmlg/web/open_api/schemas.ex`:

```elixir
defmodule GSMLG.Web.OpenApi.Schemas do
  @moduledoc false

  def components do
    %{
      "schemas" => %{},
      "securitySchemes" => %{
        "bearerAuth" => %{
          "type" => "http",
          "scheme" => "bearer",
          "bearerFormat" => "JWT",
          "description" => "Guardian access token"
        }
      }
    }
  end
end
```

Create `apps/gsmlg_web/lib/gsmlg/web/open_api/operations.ex`:

```elixir
defmodule GSMLG.Web.OpenApi.Operations do
  @moduledoc false

  alias GSMLG.Web.OpenApi.Operation

  def paths do
    %{
      "/api/openapi.json" => %{
        "get" =>
          Operation.operation(
            "getOpenApiDocument",
            "Discovery",
            "Return the OpenAPI document",
            %{
              "200" =>
                Operation.response(
                  "OpenAPI 3.0.3 document",
                  "application/json",
                  %{"type" => "object", "additionalProperties" => true}
                )
            }
          )
      }
    }
  end
end
```

- [ ] **Step 6: Add the root API specification**

Create `apps/gsmlg_web/lib/gsmlg/web/api_spec.ex`:

```elixir
defmodule GSMLG.Web.ApiSpec do
  @moduledoc false

  @behaviour OpenApiSpex.OpenApi

  alias GSMLG.Web.OpenApi.{Operations, Schemas}
  alias OpenApiSpex.OpenApi

  @impl OpenApiSpex.OpenApi
  def spec do
    OpenApi.from_map(%{
      "openapi" => "3.0.3",
      "info" => %{
        "title" => "GSMLG Web API",
        "version" => to_string(Application.spec(:gsmlg_web, :vsn) || "0.1.0"),
        "description" => "REST API published by the GSMLG public web application"
      },
      "servers" => [%{"url" => "/"}],
      "paths" => Operations.paths(),
      "components" => Schemas.components()
    })
  end
end
```

- [ ] **Step 7: Publish the OpenAPI route without validation**

Add this pipeline to `GSMLG.Web.Router`:

```elixir
pipeline :api_docs do
  plug(:put_format, :json)
  plug(OpenApiSpex.Plug.PutApiSpec, module: GSMLG.Web.ApiSpec)
end
```

Before the generic `/api/*request_path` fallback, add a scope without a
Phoenix module alias:

```elixir
scope "/api" do
  pipe_through(:api_docs)

  get("/openapi.json", OpenApiSpex.Plug.RenderSpec, [])
end
```

Do not add `CastAndValidate`, `Cast`, or `Validate` anywhere.

- [ ] **Step 8: Run the endpoint test and verify GREEN**

Run:

```bash
mix test apps/gsmlg_web/test/gsmlg_web/controllers/open_api_controller_test.exs
```

Expected: 1 test, 0 failures.

- [ ] **Step 9: Stop at checkpoint 2**

Review `git diff --check`. Suggested commit if explicitly authorized:
`feat(web): publish OpenAPI foundation`.

### Task 3: Define Runtime-Faithful Shared Schemas

**Files:**

- Modify: `apps/gsmlg_web/lib/gsmlg/web/open_api/schemas.ex`
- Create: `apps/gsmlg_web/test/gsmlg_web/open_api_spec_test.exs`

- [ ] **Step 1: Write failing component-schema assertions**

Create `apps/gsmlg_web/test/gsmlg_web/open_api_spec_test.exs`:

```elixir
defmodule GSMLG.Web.OpenApiSpecTest do
  use ExUnit.Case, async: true

  alias GSMLG.Web.ApiSpec
  alias OpenApiSpex.OpenApi

  test "defines the exact shared runtime schemas" do
    document = ApiSpec.spec() |> OpenApi.to_map()
    schemas = document["components"]["schemas"]

    assert schemas["Note"]["required"] ==
             ~w(id title content labels attachments created_at updated_at)

    assert schemas["NoteCreateInput"]["required"] == ~w(title content)
    assert schemas["NoteUpdateInput"]["required"] == ["attachments"]
    assert schemas["AttachmentInput"]["additionalProperties"] == false
    assert schemas["WebPushSubscriptionInput"]["required"] == ["subscription"]
    assert schemas["ApiError"]["required"] == ["errors"]
  end

  test "defines Guardian bearer authentication" do
    document = ApiSpec.spec() |> OpenApi.to_map()

    assert document["components"]["securitySchemes"]["bearerAuth"] == %{
             "type" => "http",
             "scheme" => "bearer",
             "bearerFormat" => "JWT",
             "description" => "Guardian access token"
           }
  end
end
```

- [ ] **Step 2: Run the schema test and verify RED**

Run:

```bash
mix test apps/gsmlg_web/test/gsmlg_web/open_api_spec_test.exs
```

Expected: missing component schemas.

- [ ] **Step 3: Replace `Schemas.components/0` with the complete schema map**

Keep the existing `securitySchemes` entry and set `schemas` to:

```elixir
%{
  "ApiError" => object(%{"errors" => free_object()}, ~w(errors)),
  "AuthError" => object(%{"message" => string()}, ~w(message)),
  "Blog" =>
    object(
      %{
        "id" => string(),
        "title" => string(),
        "date" => nullable(string("date")),
        "author" => nullable(string()),
        "content" => string(),
        "slug" => string()
      },
      ~w(id title date author content slug)
    ),
  "BlogList" => object(%{"data" => array(ref("Blog"))}, ~w(data)),
  "Label" =>
    object(
      %{
        "key" => string(),
        "value" => string(),
        "value_type" => string(),
        "description" => string(),
        "status" => string(),
        "errors" => array(string())
      },
      ~w(key value value_type description status errors)
    ),
  "LabelSetting" =>
    object(
      %{
        "id" => string(),
        "name" => string(),
        "key" => string(),
        "color" => nullable(string()),
        "description" => string(),
        "value_type" => string(),
        "metadata" => free_object()
      },
      ~w(id name key color description value_type metadata)
    ),
  "Attachment" =>
    object(
      %{
        "id" => string(),
        "path" => string(),
        "mime" => string(),
        "description" => string(),
        "content_url" => string()
      },
      ~w(id path mime description content_url)
    ),
  "Note" =>
    object(
      %{
        "id" => string(),
        "title" => string(),
        "content" => string(),
        "labels" => array(ref("Label")),
        "attachments" => array(ref("Attachment")),
        "created_at" => nullable(string("date-time")),
        "updated_at" => nullable(string("date-time"))
      },
      ~w(id title content labels attachments created_at updated_at)
    ),
  "NoteEnvelope" => object(%{"data" => ref("Note")}, ~w(data)),
  "NoteList" => object(%{"data" => array(ref("Note"))}, ~w(data)),
  "LabelSettingList" => object(%{"data" => array(ref("LabelSetting"))}, ~w(data)),
  "AttachmentInput" =>
    object(
      %{
        "id" => string(),
        "path" => string(),
        "mime" => string(),
        "description" => string(),
        "content" => string(),
        "content_base64" => string("byte")
      },
      ~w(id path mime),
      false
    ),
  "NoteCreateInput" =>
    object(
      %{
        "title" => string(),
        "content" => string(),
        "labels" => array(string()),
        "attachments" => array(ref("AttachmentInput"))
      },
      ~w(title content),
      false
    ),
  "NoteUpdateInput" =>
    object(
      %{
        "title" => string(),
        "content" => string(),
        "labels" => array(string()),
        "attachments" => array(ref("AttachmentInput"))
      },
      ~w(attachments),
      false
    ),
  "GeoData" => free_object(),
  "GeoEnvelope" => object(%{"data" => ref("GeoData")}, ~w(data)),
  "WhoisEnvelope" =>
    object(
      %{
        "data" =>
          array(%{
            "type" => "array",
            "items" => string(),
            "minItems" => 2,
            "maxItems" => 2
          })
      },
      ~w(data)
    ),
  "RdapEnvelope" => object(%{"data" => free_object()}, ~w(data)),
  "MacVendorEnvelope" =>
    object(
      %{
        "data" => object(%{"short" => string(), "full" => string()}, ~w(short full))
      },
      ~w(data)
    ),
  "SimpleError" => object(%{"error" => string()}, ~w(error)),
  "VapidKeyEnvelope" =>
    object(%{"public_key" => nullable(string())}, ~w(public_key)),
  "WebPushSubscriptionInput" =>
    object(
      %{
        "subscription" =>
          object(
            %{
              "endpoint" => string("uri"),
              "keys" => free_object(),
              "expiration_time" => nullable(%{"type" => "integer"})
            },
            ~w(endpoint keys)
          )
      },
      ~w(subscription)
    ),
  "NotificationInput" =>
    object(%{"title" => string(), "body" => string()}, ~w(title body)),
  "StatusEnvelope" => object(%{"status" => string()}, ~w(status)),
  "SubscriptionError" => object(%{"errors" => string()}, ~w(errors))
}
```

Add these private helpers to the same module:

```elixir
defp ref(name), do: %{"$ref" => "#/components/schemas/#{name}"}

defp object(properties, required \\ [], additional_properties \\ true) do
  %{
    "type" => "object",
    "properties" => properties,
    "required" => required,
    "additionalProperties" => additional_properties
  }
end

defp free_object, do: %{"type" => "object", "additionalProperties" => true}
defp array(items), do: %{"type" => "array", "items" => items}
defp string, do: %{"type" => "string"}
defp string(format), do: %{"type" => "string", "format" => format}
defp nullable(schema), do: Map.put(schema, "nullable", true)
```

- [ ] **Step 4: Run the schema tests and verify GREEN**

Run:

```bash
mix test apps/gsmlg_web/test/gsmlg_web/open_api_spec_test.exs
```

Expected: 2 tests, 0 failures.

- [ ] **Step 5: Stop at checkpoint 3**

Review schema names, required fields, and `git diff --check`. Suggested commit
if explicitly authorized: `feat(web): describe public API schemas`.

### Task 4: Describe Blog and GaoNote Operations

**Files:**

- Create: `apps/gsmlg_web/lib/gsmlg/web/open_api/blog_operations.ex`
- Create: `apps/gsmlg_web/lib/gsmlg/web/open_api/gao_note_operations.ex`
- Modify: `apps/gsmlg_web/lib/gsmlg/web/open_api/operations.ex`
- Modify: `apps/gsmlg_web/test/gsmlg_web/open_api_spec_test.exs`

- [ ] **Step 1: Add a failing exact-operation test**

Append to `GSMLG.Web.OpenApiSpecTest`:

```elixir
test "describes blog and GaoNote operations with their runtime security" do
  document = ApiSpec.spec() |> OpenApi.to_map()

  expected = MapSet.new([
    {:get, "/api/blogs"},
    {:get, "/api/gao_notes"},
    {:get, "/api/gao_notes/label_settings"},
    {:get, "/api/gao_notes/{id}"},
    {:post, "/api/gao_notes"},
    {:put, "/api/gao_notes/{id}"},
    {:patch, "/api/gao_notes/{id}"},
    {:get, "/api/gao_notes/{note_id}/attachments/{path}"}
  ])

  assert MapSet.subset?(expected, operation_pairs(document))
  assert get_in(document, ["paths", "/api/gao_notes", "get", "security"]) ==
           [%{}, %{"bearerAuth" => []}]

  assert get_in(document, ["paths", "/api/gao_notes", "post", "security"]) ==
           [%{"bearerAuth" => []}]
end
```

Add this test helper inside the module:

```elixir
defp operation_pairs(document) do
  for {path, path_item} <- document["paths"],
      {verb, operation} <- path_item,
      verb in ~w(get post put patch delete),
      is_map(operation),
      into: MapSet.new() do
    {String.to_atom(verb), path}
  end
end
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
mix test apps/gsmlg_web/test/gsmlg_web/open_api_spec_test.exs
```

Expected: the eight business operations are missing.

- [ ] **Step 3: Define the blog-list operation**

Create `apps/gsmlg_web/lib/gsmlg/web/open_api/blog_operations.ex`:

```elixir
defmodule GSMLG.Web.OpenApi.BlogOperations do
  @moduledoc false

  alias GSMLG.Web.OpenApi.Operation

  def paths do
    %{
      "/api/blogs" => %{
        "get" =>
          Operation.operation(
            "listBlogs",
            "Blogs",
            "List published blogs",
            %{"200" => Operation.json_response("Blog list", "BlogList")},
            security: Operation.anonymous_or_bearer()
          )
      }
    }
  end
end
```

- [ ] **Step 4: Define all GaoNote operations**

Create `apps/gsmlg_web/lib/gsmlg/web/open_api/gao_note_operations.ex`:

```elixir
defmodule GSMLG.Web.OpenApi.GaoNoteOperations do
  @moduledoc false

  alias GSMLG.Web.OpenApi.Operation

  def paths do
    %{
      "/api/gao_notes" => %{
        "get" => list_notes(),
        "post" => create_note()
      },
      "/api/gao_notes/label_settings" => %{"get" => list_label_settings()},
      "/api/gao_notes/{id}" => %{
        "get" => get_note(),
        "put" => update_note("replaceNote"),
        "patch" => update_note("patchNote")
      },
      "/api/gao_notes/{note_id}/attachments/{path}" => %{
        "get" => get_attachment()
      }
    }
  end

  defp list_notes do
    Operation.operation(
      "listGaoNotes",
      "GaoNote",
      "List and search public notes",
      %{"200" => Operation.json_response("Note list", "NoteList")},
      security: Operation.anonymous_or_bearer(),
      parameters: [
        Operation.parameter("search", "query", %{"type" => "string"}, "Full-text search"),
        Operation.parameter("query", "query", %{"type" => "string"}, "Alias for search"),
        Operation.parameter(
          "label",
          "query",
          %{"type" => "array", "items" => %{"type" => "string"}},
          "Repeated key or key=value label selector"
        ),
        Operation.parameter("limit", "query", %{"type" => "integer"}, "Result limit"),
        Operation.parameter("offset", "query", %{"type" => "integer"}, "Result offset")
      ]
    )
  end

  defp list_label_settings do
    Operation.operation(
      "listGaoNoteLabelSettings",
      "GaoNote",
      "List public label settings",
      %{"200" => Operation.json_response("Label-setting list", "LabelSettingList")},
      security: Operation.anonymous_or_bearer(),
      parameters: [
        Operation.parameter("limit", "query", %{"type" => "integer"}, "Result limit")
      ]
    )
  end

  defp get_note do
    Operation.operation(
      "getGaoNote",
      "GaoNote",
      "Fetch a public note",
      %{
        "200" => Operation.json_response("Note", "NoteEnvelope"),
        "404" => Operation.json_response("Not found", "ApiError")
      },
      security: Operation.anonymous_or_bearer(),
      parameters: [id_parameter()]
    )
  end

  defp create_note do
    Operation.operation(
      "createGaoNote",
      "GaoNote",
      "Create a note",
      write_responses("Created note", "201"),
      security: Operation.bearer(),
      request_body: Operation.request_body("NoteCreateInput", "Note and attachment input")
    )
  end

  defp update_note(operation_id) do
    Operation.operation(
      operation_id,
      "GaoNote",
      "Update a note and replace its complete attachment generation",
      write_responses("Updated note", "200")
      |> Map.put("404", Operation.json_response("Not found", "ApiError")),
      security: Operation.bearer(),
      parameters: [id_parameter()],
      request_body: Operation.request_body("NoteUpdateInput", "Replacement note input")
    )
  end

  defp get_attachment do
    binary = %{"type" => "string", "format" => "binary"}

    Operation.operation(
      "getGaoNoteAttachment",
      "GaoNote",
      "Stream authenticated attachment content",
      %{
        "200" => Operation.response("Complete attachment", "application/octet-stream", binary),
        "206" => Operation.response("Attachment byte range", "application/octet-stream", binary),
        "400" => Operation.json_response("Malformed request path", "ApiError"),
        "401" => Operation.json_response("Authentication failed", "AuthError"),
        "404" => Operation.json_response("Not found", "ApiError"),
        "416" => Operation.response("Unsatisfiable byte range"),
        "503" => Operation.json_response("Storage unavailable", "ApiError")
      },
      security: Operation.bearer(),
      parameters: [
        Operation.parameter("note_id", "path", %{"type" => "string"}, "Note identifier", true),
        Operation.parameter(
          "path",
          "path",
          %{"type" => "string"},
          "Slash-separated attachment path; encode each path segment",
          true
        ),
        Operation.parameter("Range", "header", %{"type" => "string"}, "Single bytes range")
      ]
    )
  end

  defp id_parameter do
    Operation.parameter("id", "path", %{"type" => "string"}, "Note identifier", true)
  end

  defp write_responses(success_description, success_status) do
    %{
      success_status => Operation.json_response(success_description, "NoteEnvelope"),
      "400" => Operation.json_response("Malformed request", "ApiError"),
      "401" => Operation.json_response("Authentication failed", "AuthError"),
      "409" => Operation.json_response("Attachment conflict", "ApiError"),
      "422" => Operation.json_response("Validation failed", "ApiError"),
      "500" => Operation.json_response("Internal server error", "ApiError")
    }
  end
end
```

- [ ] **Step 5: Merge the new path modules into the central inventory**

Replace `Operations.paths/0` with:

```elixir
alias GSMLG.Web.OpenApi.{BlogOperations, GaoNoteOperations, Operation}

def paths do
  self_path()
  |> Map.merge(BlogOperations.paths())
  |> deep_merge_paths(GaoNoteOperations.paths())
end

defp self_path do
  %{
    "/api/openapi.json" => %{
      "get" =>
        Operation.operation(
          "getOpenApiDocument",
          "Discovery",
          "Return the OpenAPI document",
          %{
            "200" =>
              Operation.response(
                "OpenAPI 3.0.3 document",
                "application/json",
                %{"type" => "object", "additionalProperties" => true}
              )
          }
        )
    }
  }
end

defp deep_merge_paths(left, right) do
  Map.merge(left, right, fn _path, left_item, right_item ->
    Map.merge(left_item, right_item)
  end)
end
```

- [ ] **Step 6: Run focused tests and verify GREEN**

Run:

```bash
mix test \
  apps/gsmlg_web/test/gsmlg_web/open_api_spec_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/open_api_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/blog_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_attachment_content_controller_test.exs
```

Expected: all focused tests pass.

- [ ] **Step 7: Stop at checkpoint 4**

Review the eight documented business operations and `git diff --check`.
Suggested commit if explicitly authorized:
`feat(web): describe blog and GaoNote APIs`.

### Task 5: Describe Toolbox, WebPush, and Proxy-Rule Operations

**Files:**

- Create: `apps/gsmlg_web/lib/gsmlg/web/open_api/toolbox_operations.ex`
- Create: `apps/gsmlg_web/lib/gsmlg/web/open_api/web_push_operations.ex`
- Create: `apps/gsmlg_web/lib/gsmlg/web/open_api/proxy_rules_operations.ex`
- Modify: `apps/gsmlg_web/lib/gsmlg/web/open_api/operations.ex`
- Modify: `apps/gsmlg_web/test/gsmlg_web/open_api_spec_test.exs`

- [ ] **Step 1: Add the failing remaining-operation test**

Append:

```elixir
test "describes every toolbox, WebPush, and proxy-rule operation" do
  document = ApiSpec.spec() |> OpenApi.to_map()

  expected = MapSet.new([
    {:get, "/api/toolbox/ip_geo"},
    {:get, "/api/toolbox/whois"},
    {:get, "/api/toolbox/whois/rdap"},
    {:get, "/api/toolbox/mac_manufacturer"},
    {:get, "/api/toolbox/ip_to_geomap"},
    {:get, "/api/vapid-public-key"},
    {:post, "/api/subscribe"},
    {:post, "/api/send-notification"},
    {:get, "/api/proxy-rules/{list}/{format}"}
  ])

  assert MapSet.subset?(expected, operation_pairs(document))
  assert get_in(document, ["paths", "/api/send-notification", "post", "security"]) ==
           [%{"bearerAuth" => []}]

  assert get_in(document, ["paths", "/api/proxy-rules/{list}/{format}", "get", "security"]) ==
           []
end
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
mix test apps/gsmlg_web/test/gsmlg_web/open_api_spec_test.exs
```

Expected: nine operations are missing.

- [ ] **Step 3: Define toolbox operations**

Create `apps/gsmlg_web/lib/gsmlg/web/open_api/toolbox_operations.ex`:

```elixir
defmodule GSMLG.Web.OpenApi.ToolboxOperations do
  @moduledoc false

  alias GSMLG.Web.OpenApi.Operation

  def paths do
    %{
      "/api/toolbox/ip_geo" => %{
        "get" => lookup("lookupIpGeo", "Look up IP geolocation", "ip", "GeoEnvelope")
      },
      "/api/toolbox/whois" => %{
        "get" => lookup("lookupWhois", "Look up raw WHOIS data", "look_for", "WhoisEnvelope")
      },
      "/api/toolbox/whois/rdap" => %{"get" => rdap()},
      "/api/toolbox/mac_manufacturer" => %{
        "get" =>
          lookup(
            "lookupMacManufacturer",
            "Look up a MAC manufacturer",
            "mac",
            "MacVendorEnvelope",
            "404"
          )
      },
      "/api/toolbox/ip_to_geomap" => %{
        "get" => lookup("mapIpGeo", "Look up IP data for a geo map", "ip", "GeoEnvelope", nil)
      }
    }
  end

  defp lookup(operation_id, summary, parameter_name, response_schema, error_status \\ "422") do
    responses = %{"200" => Operation.json_response("Lookup result", response_schema)}

    responses =
      if error_status do
        Map.put(responses, error_status, Operation.json_response("Lookup failed", "SimpleError"))
      else
        responses
      end

    Operation.operation(operation_id, "Toolbox", summary, responses,
      security: Operation.anonymous_or_bearer(),
      parameters: [
        Operation.parameter(
          parameter_name,
          "query",
          %{"type" => "string"},
          "Lookup value",
          true
        )
      ]
    )
  end

  defp rdap do
    Operation.operation(
      "lookupRdap",
      "Toolbox",
      "Look up RDAP data",
      %{
        "200" => Operation.json_response("RDAP result", "RdapEnvelope"),
        "422" => Operation.json_response("Lookup failed", "SimpleError")
      },
      security: Operation.anonymous_or_bearer(),
      parameters: [
        Operation.parameter(
          "look_for",
          "query",
          %{"type" => "string"},
          "Domain, IP address, or ASN",
          true
        ),
        Operation.parameter(
          "type",
          "query",
          %{"type" => "string", "enum" => ~w(domain ip asn), "default" => "domain"},
          "RDAP lookup type"
        )
      ]
    )
  end
end
```

- [ ] **Step 4: Define WebPush operations**

Create `apps/gsmlg_web/lib/gsmlg/web/open_api/web_push_operations.ex`:

```elixir
defmodule GSMLG.Web.OpenApi.WebPushOperations do
  @moduledoc false

  alias GSMLG.Web.OpenApi.Operation

  def paths do
    %{
      "/api/vapid-public-key" => %{
        "get" =>
          Operation.operation(
            "getVapidPublicKey",
            "WebPush",
            "Return the VAPID public key",
            %{"200" => Operation.json_response("VAPID public key", "VapidKeyEnvelope")},
            security: Operation.anonymous_or_bearer()
          )
      },
      "/api/subscribe" => %{
        "post" =>
          Operation.operation(
            "subscribeWebPush",
            "WebPush",
            "Store a WebPush subscription",
            %{
              "200" => Operation.json_response("Subscription stored", "StatusEnvelope"),
              "422" => Operation.json_response("Subscription storage failed", "SubscriptionError")
            },
            security: Operation.anonymous_or_bearer(),
            request_body:
              Operation.request_body("WebPushSubscriptionInput", "WebPush subscription")
          )
      },
      "/api/send-notification" => %{
        "post" =>
          Operation.operation(
            "sendWebPushNotification",
            "WebPush",
            "Attempt notification delivery to stored subscriptions",
            %{
              "200" => Operation.json_response("Dispatch attempted", "StatusEnvelope"),
              "401" => Operation.json_response("Authentication failed", "AuthError")
            },
            security: Operation.bearer(),
            request_body: Operation.request_body("NotificationInput", "Notification payload")
          )
      }
    }
  end
end
```

- [ ] **Step 5: Define proxy-rule artifact documentation**

Create `apps/gsmlg_web/lib/gsmlg/web/open_api/proxy_rules_operations.ex`:

```elixir
defmodule GSMLG.Web.OpenApi.ProxyRulesOperations do
  @moduledoc false

  alias GSMLG.Web.OpenApi.Operation

  def paths do
    %{
      "/api/proxy-rules/{list}/{format}" => %{
        "get" =>
          Operation.operation(
            "getProxyRules",
            "ProxyRules",
            "Return a pre-rendered proxy-rule artifact",
            %{
              "200" =>
                Operation.response(
                  "Rendered artifact",
                  "text/plain",
                  %{"type" => "string"}
                ),
              "304" => Operation.response("Not modified"),
              "404" => Operation.response("Unknown list or format"),
              "503" => Operation.response("Artifact is not ready")
            },
            parameters: [
              Operation.parameter(
                "list",
                "path",
                %{"type" => "string", "enum" => ~w(proxy-list direct-list)},
                "Rule list",
                true
              ),
              Operation.parameter(
                "format",
                "path",
                %{"type" => "string", "enum" => ~w(raw squid clash)},
                "Artifact format",
                true
              ),
              Operation.parameter(
                "If-None-Match",
                "header",
                %{"type" => "string"},
                "Conditional ETag"
              )
            ]
          )
      }
    }
  end
end
```

- [ ] **Step 6: Merge all three path inventories**

Add aliases for `ToolboxOperations`, `WebPushOperations`, and
`ProxyRulesOperations` to `Operations`, then extend `paths/0`:

```elixir
def paths do
  self_path()
  |> deep_merge_paths(BlogOperations.paths())
  |> deep_merge_paths(GaoNoteOperations.paths())
  |> deep_merge_paths(ToolboxOperations.paths())
  |> deep_merge_paths(WebPushOperations.paths())
  |> deep_merge_paths(ProxyRulesOperations.paths())
end
```

- [ ] **Step 7: Run focused tests and verify GREEN**

Run:

```bash
mix test \
  apps/gsmlg_web/test/gsmlg_web/open_api_spec_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/open_api_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/proxy_rules_controller_test.exs
```

Expected: focused tests pass and the document now contains all 17 business
operations plus its own operation.

- [ ] **Step 8: Stop at checkpoint 5**

Review the nine new operations and `git diff --check`. Suggested commit if
explicitly authorized: `feat(web): describe toolbox and service APIs`.

### Task 6: Add RFC 9727 API Catalog Discovery

**Files:**

- Create: `apps/gsmlg_web/lib/gsmlg/web/controllers/api_catalog_controller.ex`
- Create: `apps/gsmlg_web/test/gsmlg_web/controllers/api_catalog_controller_test.exs`
- Modify: `apps/gsmlg_web/lib/gsmlg/web/router.ex`

- [ ] **Step 1: Write failing GET and HEAD catalog tests**

Create
`apps/gsmlg_web/test/gsmlg_web/controllers/api_catalog_controller_test.exs`:

```elixir
defmodule GSMLG.Web.ApiCatalogControllerTest do
  use GSMLG.Web.ConnCase, async: true

  @profile "https://www.rfc-editor.org/info/rfc9727"
  @content_type ~s(application/linkset+json; profile="#{@profile}")

  test "GET publishes the RFC 9727 Linkset", %{conn: conn} do
    conn = get(conn, "/.well-known/api-catalog")

    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") == [@content_type]
    assert get_resp_header(conn, "link") == [
             ~s(</.well-known/api-catalog>; rel="api-catalog")
           ]

    assert %{
             "linkset" => [
               %{
                 "anchor" => "/api",
                 "service-desc" => [
                   %{"href" => "/api/openapi.json", "type" => "application/json"}
                 ]
               }
             ]
           } = Jason.decode!(conn.resp_body)
  end

  test "HEAD publishes discovery headers without a body", %{conn: conn} do
    conn = head(conn, "/.well-known/api-catalog")

    assert response(conn, 200) == ""
    assert get_resp_header(conn, "content-type") == [@content_type]
    assert get_resp_header(conn, "link") == [
             ~s(</.well-known/api-catalog>; rel="api-catalog")
           ]
  end

  test "catalog does not advertise excluded transports or routes", %{conn: conn} do
    body = conn |> get("/.well-known/api-catalog") |> response(200)

    refute body =~ "/mcp"
    refute body =~ "/files"
    refute body =~ "/admin"
    refute body =~ "/api/sign_in"
    refute body =~ "/api/blogs/{id}"
  end
end
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
mix test apps/gsmlg_web/test/gsmlg_web/controllers/api_catalog_controller_test.exs
```

Expected: `404` because the catalog route does not exist.

- [ ] **Step 3: Implement the deterministic Linkset controller**

Create
`apps/gsmlg_web/lib/gsmlg/web/controllers/api_catalog_controller.ex`:

```elixir
defmodule GSMLG.Web.ApiCatalogController do
  use GSMLG.Web, :controller

  @profile "https://www.rfc-editor.org/info/rfc9727"
  @content_type ~s(application/linkset+json; profile="#{@profile}")
  @link ~s(</.well-known/api-catalog>; rel="api-catalog")

  def show(conn, _params) do
    body =
      Jason.encode!(%{
        "linkset" => [
          %{
            "anchor" => "/api",
            "service-desc" => [
              %{"href" => "/api/openapi.json", "type" => "application/json"}
            ]
          }
        ]
      })

    conn
    |> put_resp_header("content-type", @content_type)
    |> put_resp_header("link", @link)
    |> send_resp(:ok, body)
  end
end
```

- [ ] **Step 4: Register the well-known route**

Before the final browser catch-all in `GSMLG.Web.Router`, add:

```elixir
scope "/.well-known", GSMLG.Web do
  pipe_through(:api)

  get("/api-catalog", ApiCatalogController, :show)
end
```

Do not add a separate `head` route; endpoint-level `Plug.Head` provides HEAD
semantics through the GET route.

- [ ] **Step 5: Run catalog and OpenAPI tests and verify GREEN**

Run:

```bash
mix test \
  apps/gsmlg_web/test/gsmlg_web/controllers/api_catalog_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/open_api_controller_test.exs
```

Expected: all discovery tests pass.

- [ ] **Step 6: Stop at checkpoint 6**

Review RFC media type, profile, Link header, relative references, and
`git diff --check`. Suggested commit if explicitly authorized:
`feat(web): add RFC API catalog discovery`.

### Task 7: Enforce Exact Router/OpenAPI Parity and Verify the Slice

**Files:**

- Modify: `apps/gsmlg_web/test/gsmlg_web/open_api_spec_test.exs`
- Modify only if the tests reveal an in-scope mismatch:
  `apps/gsmlg_web/lib/gsmlg/web/open_api/*.ex`

- [ ] **Step 1: Add the failing exact drift test**

Append to `GSMLG.Web.OpenApiSpecTest`:

```elixir
test "OpenAPI exactly matches every supported /api operation" do
  document = ApiSpec.spec() |> OpenApi.to_map()

  router_operations =
    GSMLG.Web.Router.__routes__()
    |> Enum.filter(fn route ->
      String.starts_with?(route.path, "/api") and
        route.verb in [:get, :post, :put, :patch, :delete] and
        route.path != "/api/*request_path"
    end)
    |> Enum.map(fn route -> {route.verb, normalize_route_path(route.path)} end)
    |> MapSet.new()

  assert operation_pairs(document) == router_operations
end

test "the final document contains 17 business operations plus itself" do
  document = ApiSpec.spec() |> OpenApi.to_map()
  operations = operation_pairs(document)

  assert MapSet.size(operations) == 18
  assert {:get, "/api/openapi.json"} in operations
  refute Enum.any?(operations, fn {_verb, path} -> String.starts_with?(path, "/mcp") end)
  refute {:get, "/api/blogs/{id}"} in operations
end

defp normalize_route_path(path) do
  path
  |> String.replace(~r/:([A-Za-z_][A-Za-z0-9_]*)/, "{\\1}")
  |> String.replace(~r/\*([A-Za-z_][A-Za-z0-9_]*)/, "{\\1}")
end
```

- [ ] **Step 2: Run the test and inspect RED if any inventory differs**

Run:

```bash
mix test apps/gsmlg_web/test/gsmlg_web/open_api_spec_test.exs
```

Expected before corrections: any verb/path naming mismatch is displayed as an
exact `MapSet` difference. Do not weaken the expected set or add exclusions;
correct only the in-scope path definition or normalization.

- [ ] **Step 3: Correct only demonstrated in-scope documentation mismatches**

Use these fixed normalization rules:

```text
/api/gao_notes/:id
  -> /api/gao_notes/{id}

/api/gao_notes/:note_id/attachments/*path
  -> /api/gao_notes/{note_id}/attachments/{path}

/api/proxy-rules/:list/:format
  -> /api/proxy-rules/{list}/{format}
```

The generic `*request_path` fallback remains the only excluded `/api` router
entry. Every explicit GET, POST, PUT, PATCH, and DELETE route must appear in
OpenAPI.

- [ ] **Step 4: Run the complete scoped test set**

Run:

```bash
mix test \
  apps/gsmlg_web/test/gsmlg_web/api_route_surface_test.exs \
  apps/gsmlg_web/test/gsmlg_web/open_api_spec_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/api_catalog_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/open_api_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/api_error_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/blog_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_attachment_content_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/proxy_rules_controller_test.exs
```

Expected: all in-scope tests pass. If a failure is outside this design, report
it and stop.

- [ ] **Step 5: Run formatting, compilation, route, and diff checks**

Run:

```bash
mix format --check-formatted \
  apps/gsmlg_web/mix.exs \
  apps/gsmlg_web/lib/gsmlg/web/application.ex \
  apps/gsmlg_web/lib/gsmlg/web/router.ex \
  apps/gsmlg_web/lib/gsmlg/web/api_spec.ex \
  apps/gsmlg_web/lib/gsmlg/web/open_api/*.ex \
  apps/gsmlg_web/lib/gsmlg/web/controllers/api_catalog_controller.ex \
  apps/gsmlg_web/test/gsmlg_web/api_route_surface_test.exs \
  apps/gsmlg_web/test/gsmlg_web/open_api_spec_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/api_catalog_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/open_api_controller_test.exs
mix compile --warnings-as-errors
mix phx.routes GSMLG.Web.Router
mix phx.routes GSMLG.AdminWeb.Router | rg '/mcp/gao_note'
git diff --check
git status --short
```

Expected:

- Formatting and compilation exit successfully. If strict compilation reports
  an unrelated pre-existing warning in another umbrella app, record it and
  stop without modifying that app.
- The public router has 17 business `/api` operations, one
  `/api/openapi.json` operation, the well-known catalog route, no dead REST
  route, and no MCP route.
- The admin router still contains `/mcp/gao_note`.
- `git diff --check` reports no whitespace errors.
- Status contains only the approved scoped files and the design/plan docs.

- [ ] **Step 6: Stop at checkpoint 7**

Present the scoped diff and verification evidence. Suggested commit if
explicitly authorized: `test(web): enforce API documentation parity`.

## Completion Checklist

- [ ] Seven dead REST routes are removed and return JSON 404 through the
      catch-all.
- [ ] `gsmlg_web` has no MCP route, origin plug, MCP tests, or MCP supervisor
      child.
- [ ] Admin MCP remains unchanged and registered.
- [ ] OpenApiSpex is passive and local to `gsmlg_web`.
- [ ] All 17 surviving business operations match runtime contracts.
- [ ] `/api/openapi.json` publishes 18 operations including itself.
- [ ] `GET` and `HEAD /.well-known/api-catalog` expose RFC 9727 Linkset
      discovery.
- [ ] Router and OpenAPI operation sets match exactly.
- [ ] No browser, file, MCP, admin, catch-all, or removed route appears in the
      OpenAPI document.
- [ ] Focused tests, formatting, strict compilation, route checks, and
      `git diff --check` have fresh passing evidence or an out-of-scope blocker
      has been reported without repair.
- [ ] No commit, push, PR, deployment, or release has occurred without explicit
      authorization.
