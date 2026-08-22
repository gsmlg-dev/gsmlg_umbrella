# GSMLG Web API Discovery Design

Date: 2026-08-18

## Status

Approved in conversation on 2026-08-18. This document records the approved
design for removing dead and misplaced routes from `gsmlg_web`, publishing a
complete OpenAPI description of its remaining REST API, and making that
description discoverable through the RFC 9727 API catalog.

## Goal

Make every supported REST API in `gsmlg_web` automatically discoverable and
machine-readable while removing routes that are not part of the public web
application's intended contract.

The completed surface will provide:

- The 19 executable business API operations under `/api` and
  `/rules/zeroomega` after integration with `main` on 2026-08-23.
- `GET /api/openapi.json` as the canonical OpenAPI document.
- `GET /.well-known/api-catalog` and RFC-compatible `HEAD` behavior for
  standards-based discovery.
- Route/spec drift checks that fail when the Phoenix router and OpenAPI
  document disagree.

The design is documentation-only for surviving operations. It does not change
request parsing, validation, response bodies, status codes, authorization, or
controller behavior.

## Scope

### Included

- Remove seven registered REST routes whose controller contract does not
  exist.
- Remove the public read-only GaoNote MCP integration from `gsmlg_web`.
- Preserve the authenticated administrative MCP endpoint in
  `gsmlg_admin_web`.
- Add OpenApiSpex to `gsmlg_web` for typed OpenAPI construction and encoding.
- Define the complete OpenAPI path and schema inventory centrally.
- Publish the OpenAPI JSON document.
- Publish an RFC 9727 Linkset JSON API catalog.
- Add focused route-removal, catalog, OpenAPI, schema, security, and drift
  tests.

### Excluded

- Browser routes and LiveViews.
- Public file delivery under `/files/*`.
- MCP from the OpenAPI document and the public web endpoint.
- Admin API documentation.
- Swagger UI or another interactive documentation site.
- OpenApiSpex request casting or validation plugs.
- Repairs or behavior changes for existing toolbox, WebPush, GaoNote, blog,
  proxy-rules, authentication, or error contracts.
- Deployment, release publication, push, or pull-request work.

## Route Cleanup

### Dead REST routes

Remove these router entries rather than repairing or documenting them:

| Method | Path | Reason |
|---|---|---|
| `POST` | `/api/sign_in` | `AuthController.sign_in/2` does not exist. |
| `POST` | `/api/sign_up` | `AuthController.sign_up/2` does not exist. |
| `DELETE` | `/api/sign_out` | `AuthController.sign_out/2` does not exist. |
| `GET` | `/api/blogs/:id` | The action matches `slug`, not the routed `id` parameter. |
| `POST` | `/api/blogs` | `BlogController.create/2` does not exist. |
| `PUT` | `/api/blogs/:id` | `BlogController.update/2` does not exist. |
| `DELETE` | `/api/blogs/:id` | `BlogController.delete/2` does not exist. |

After removal, requests using these method/path combinations continue through
the existing `/api/*request_path` JSON fallback and return the normal API 404
response. Browser authentication and browser blog routes remain unchanged.

### Public MCP integration

Remove from `gsmlg_web`:

- The `:mcp_public_api` pipeline.
- The `/mcp/gao_note` forwarded route.
- `GSMLG.GaoNote.MCP.ReadOnlyServer` from `GSMLG.Web.Application` children.
- `GSMLG.Web.Plugs.VerifyMCPOrigin`.
- The `gsmlg_web` read-only MCP controller tests.

Do not modify:

- The `/mcp/gao_note` route in `GSMLG.AdminWeb.Router`.
- `GSMLG.GaoNote.MCP.AdminServer` supervision in `GSMLG.AdminWeb.Application`.
- Admin MCP authentication, origin verification, LiveView, or tests.
- Reusable MCP modules inside `gsmlg_gao_note`; removing an HTTP exposure from
  `gsmlg_web` does not require redesigning that application.

## Surviving Business API Inventory

The canonical business inventory contains exactly 19 operations.

### Public or optionally authenticated operations

| Method | Path | Contract summary |
|---|---|---|
| `GET` | `/api/blogs` | List published blogs. |
| `GET` | `/api/gao_notes` | List/search public notes with label and pagination filters. |
| `GET` | `/api/gao_notes/label_settings` | List public label settings. |
| `GET` | `/api/gao_notes/:id` | Fetch one public note. |
| `GET` | `/api/toolbox/ip_geo` | Look up geolocation by `ip`. |
| `GET` | `/api/toolbox/whois` | Raw WHOIS lookup by `look_for`. |
| `GET` | `/api/toolbox/whois/rdap` | RDAP lookup by `look_for` and optional `type`. |
| `GET` | `/api/toolbox/mac_manufacturer` | MAC vendor lookup by `mac`. |
| `GET` | `/api/toolbox/ip_to_geomap` | Geo-map lookup by `ip`. |
| `GET` | `/api/vapid-public-key` | Return the WebPush VAPID public key. |
| `POST` | `/api/subscribe` | Store a WebPush subscription. |
| `GET` | `/api/proxy-rules/:list/:format` | Return a pre-rendered proxy-rule artifact. |

The first eleven operations pass through optional Guardian bearer processing.
Proxy-rule delivery does not use the Guardian pipeline.

### Required bearer-token operations

| Method | Path | Contract summary |
|---|---|---|
| `GET` | `/api/gao_notes/:note_id/attachments/*path` | Stream authenticated attachment content, including byte ranges. |
| `POST` | `/api/gao_notes` | Create a note and optional attachment generation. |
| `PUT` | `/api/gao_notes/:id` | Replace note fields and the complete attachment generation. |
| `PATCH` | `/api/gao_notes/:id` | Same runtime mutation contract as `PUT`. |
| `POST` | `/api/send-notification` | Attempt notification delivery to stored subscriptions. |

### Public ZeroOmega artifact operations

| Method | Path | Contract summary |
|---|---|---|
| `GET` | `/rules/zeroomega/switchy` | Export SwitchyOmega conditions with optional profile parameters. |
| `GET` | `/rules/zeroomega/pac` | Export a parameterized proxy auto-configuration script. |

These two operations were added to `main` after the original design approval
and incorporated during local integration on 2026-08-23. They are public,
support conditional requests, and remain outside the Guardian pipeline.

## Selected OpenAPI Approach

Use OpenApiSpex in `gsmlg_web`, with an explicit central specification module
such as `GSMLG.Web.ApiSpec` and focused schema modules under
`GSMLG.Web.OpenApi`.

The OpenAPI version will be `3.0.3`, matching OpenApiSpex's supported OpenAPI 3
model. The document will be compiled into BEAM modules and rendered at request
time from those immutable definitions. It will not require runtime file reads,
static asset copying, digest changes, a new supervision child, or release
overlay changes.

### Why paths are central rather than controller-derived

Do not attach operation annotations to controllers and call
`OpenApiSpex.Paths.from_router/1` for the complete surface. Some controllers
serve both browser and API routes with the same action, and the current router
contains catch-alls and intentionally excluded paths. Automatic extraction
would make it too easy to publish browser, dead, or transport routes.

Instead, `GSMLG.Web.ApiSpec` owns the exact path inventory. A separate test
compares that inventory with normalized Phoenix routes, giving explicit drift
detection without coupling documentation generation to ambiguous controller
actions.

### Passive documentation boundary

The OpenApiSpex dependency is used only for:

- Typed OpenAPI documents, operations, parameters, schemas, responses, and
  security schemes.
- Schema reference resolution and consistency checks.
- JSON rendering of `/api/openapi.json`.

Do not add `OpenApiSpex.Plug.CastAndValidate`, `Cast`, or `Validate` to any
existing pipeline or controller. Those plugs can alter parameter types,
short-circuit requests, and introduce new validation responses. This feature
must describe the current runtime contract, not change it.

## OpenAPI Document

### Endpoint

`GET /api/openapi.json` is public and uses a dedicated documentation pipeline
that loads `GSMLG.Web.ApiSpec` before rendering it. It is not placed behind
Guardian authentication. It returns `application/json`, and the API catalog's
`service-desc` link declares the same representation type.

The OpenAPI document describes:

- The 19 business operations above.
- Its own `GET /api/openapi.json` operation.

It therefore contains 20 OpenAPI operations. The RFC catalog endpoint is the
bootstrap mechanism and is not duplicated as an OpenAPI operation.

### Security representation

Define one HTTP bearer security scheme for Guardian access tokens.

- Optionally authenticated operations declare anonymous-or-bearer security.
- Required operations declare bearer-only security.
- Proxy-rule artifacts and the OpenAPI document declare no authentication
  requirement.

The specification documents authentication; it does not validate tokens or
change Guardian behavior.

### Contract fidelity

Schemas must describe the real runtime shapes, including:

- Blog list envelopes.
- GaoNote, typed labels, label settings, attachment metadata, write inputs,
  structured write errors, and auth errors.
- The identical current `PUT` and `PATCH` mutation semantics.
- Attachment wildcard paths, byte-range headers, raw binary responses,
  `206`, `416`, and storage failure responses.
- Toolbox query strings and their existing result/error envelopes.
- WebPush subscription, public-key, and notification result shapes without
  claiming runtime validation that does not exist.
- Proxy list/format enums, conditional request headers, non-JSON content,
  `304`, `404`, and `503` responses.
- The existing JSON API 404 envelope where applicable.

Known runtime weaknesses, such as function-head failures for missing toolbox
or WebPush inputs, ignored notification delivery results, and inconsistent
legacy error envelopes, are documented truthfully when externally observable.
They are not repaired in this scope.

## RFC 9727 API Catalog

### Endpoint behavior

Publish `/.well-known/api-catalog` without browser session, CSRF, or Guardian
requirements.

`GET` returns a Linkset JSON document with:

- `Content-Type: application/linkset+json`.
- The profile URI `https://www.rfc-editor.org/info/rfc9727` as a media-type
  profile parameter.
- One catalog entry anchored to the public `/api` namespace.
- A `service-desc` link to `/api/openapi.json` with a media type matching the
  rendered OpenAPI representation.

The existing endpoint-level `Plug.Head` converts `HEAD` to the matching GET
route and suppresses the response body. The catalog controller must put a
`Link` response header using the registered `api-catalog` relation before the
body is rendered so GET and HEAD both expose it.

Relative URI references are preferred in the Linkset and Link header. Clients
resolve them against the origin that served the catalog, avoiding incorrect
hostnames behind development ports or production proxies.

## Error Handling

- Unknown discovery paths continue to the existing browser or API fallback as
  appropriate.
- The API catalog has no database or external service dependency and should
  render deterministically.
- OpenAPI construction or reference failures are caught by tests and compile
  checks; they must not be hidden by a partial document.
- Existing business endpoint errors are described, not intercepted.

## Drift Prevention

Add a contract test that obtains the Phoenix route inventory and normalizes it
to OpenAPI method/path pairs. In particular:

- `:id` and other Phoenix segments become `{id}`.
- `*path` becomes the documented attachment path parameter.
- The generic API catch-all is excluded explicitly.
- Browser, file, MCP, admin, and well-known routes are outside the business
  comparison. The comparison includes both `/api` and `/rules/zeroomega`.
- `/api/openapi.json` is asserted separately as the one documentation
  operation.

The test compares the exact surviving router set with the OpenAPI set. It must
fail when a route is added without documentation, documentation names a route
that no longer exists, or an excluded transport/browser route leaks into the
specification.

## Testing Strategy

Implementation follows test-first slices.

### Route cleanup tests

- Assert the seven dead method/path pairs are absent from the router.
- Assert representative removed requests receive the JSON API 404 response.
- Assert no `gsmlg_web` MCP route or MCP application child remains.
- Preserve the existing admin MCP route and its existing test suite without
  editing admin behavior.

### API catalog tests

- GET returns `200`, Linkset JSON, the RFC profile media type, the expected
  anchor, and the OpenAPI `service-desc` link.
- HEAD returns `200`, an empty body, and the required `Link` header.
- The catalog never advertises MCP, browser pages, files, admin endpoints, or
  removed routes.

### OpenAPI tests

- The OpenApiSpex document resolves all schema references and encodes to JSON.
- `/api/openapi.json` returns `200` with `application/json`.
- The document contains exactly the 19 surviving business operations plus its
  own operation.
- Security is anonymous-or-bearer, bearer-only, or absent as designed.
- Representative request, response, error, wildcard, range, conditional, and
  non-JSON schemas match controller contracts.
- Router/OpenAPI operation sets match exactly after documented normalization.

### Scoped verification

Run only `gsmlg_web` controller and API-spec tests, plus formatting, strict
compilation, and route inventory checks relevant to the changed application.
Inspect the admin route inventory to confirm its MCP endpoint remains, without
broadening implementation into `gsmlg_admin_web`.

## Expected File Map

### Modify

- `apps/gsmlg_web/mix.exs`
- `mix.lock`
- `apps/gsmlg_web/lib/gsmlg/web/router.ex`
- `apps/gsmlg_web/lib/gsmlg/web/application.ex`

### Create

- `apps/gsmlg_web/lib/gsmlg/web/api_spec.ex`
- Focused modules under `apps/gsmlg_web/lib/gsmlg/web/open_api/`
- `apps/gsmlg_web/lib/gsmlg/web/controllers/api_catalog_controller.ex`
- `apps/gsmlg_web/test/gsmlg_web/controllers/api_catalog_controller_test.exs`
- `apps/gsmlg_web/test/gsmlg_web/controllers/open_api_controller_test.exs`
- `apps/gsmlg_web/test/gsmlg_web/open_api_spec_test.exs`
- A focused route-surface test under `apps/gsmlg_web/test/gsmlg_web/`

### Delete

- `apps/gsmlg_web/lib/gsmlg/web/plugs/verify_mcp_origin.ex`
- `apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_mcp_controller_test.exs`

The implementation plan may split OpenAPI schemas into multiple small files to
keep domain contracts readable. It must not introduce files outside this map
without identifying a concrete requirement from the approved scope.

## Completion Criteria

The work is complete when:

1. The seven dead REST routes are absent and return the normal API 404.
2. `gsmlg_web` exposes and supervises no MCP transport.
3. The admin MCP route remains unchanged and registered.
4. The 19 surviving business operations are represented faithfully.
5. `/api/openapi.json` publishes a valid OpenAPI document with 20 operations
   including itself.
6. `GET` and `HEAD /.well-known/api-catalog` satisfy the selected RFC 9727
   behavior and advertise the OpenAPI document.
7. Route/spec drift tests enforce the exact boundary.
8. Focused tests, strict compilation, formatting, and diff checks pass.
9. No Swagger UI, MCP exposure, runtime validation, unrelated repair,
   deployment, push, or release work is added.
