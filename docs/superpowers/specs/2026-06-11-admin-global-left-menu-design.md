# Admin Global Left Menu Design

Date: 2026-06-11

## Goal

Update the admin UI so authenticated admin pages share one primary, persistent left navigation. The left menu should mirror the current technical modules, replace module-specific sidebars, and become the main post-sign-in navigation surface.

The appbar must remain unchanged until the left menu migration is complete.

## Design Direction

The admin UI is a dense operational interface. The navigation should favor scanning, predictable grouping, and stable placement over decorative layout. It should use the Phoenix DuskMoon design system:

- Page body: `bg-surface text-on-surface`
- Appbar: unchanged existing primary appbar
- Sidebar: `bg-secondary text-secondary-content`
- Content: surface-based admin pages
- No hardcoded color palette classes in new navigation code
- Disabled entries remain visible but not clickable

## Menu Model

Use a centralized three-level tree:

1. Section
2. Group
3. Item

The implementation should add a single menu data module, `GSMLG.AdminWeb.AdminMenu`, that owns the tree and helper functions for active matching, open branch detection, and disabled state handling.

## Menu Structure

```text
Dashboard
  Overview
    Admin Home -> /
    Live Dashboard -> /live_dashboard

Content
  Users
    User List -> /users
    User Tokens -> /user_tokens
  Blogs
    Blog List -> /blogs
    Import -> /blogs/import
    New Blog -> /blogs/new
    Settings -> /blogs/settings
  Integrations
    Web Push -> /web_push
    API Providers -> /api_providers
    Github -> /github

Cloud
  AWS
    DynamoDB: Table List -> /aws/dynamo_db
    Lightsail: Instance -> disabled placeholder
    Route53: Hosted Zones -> /aws/route53/hosted_zones
    S3: Bucket List -> /aws/s3/buckets

Service
  Cluster
    Node Management -> /node_management
  Command Platform
    Commander Dashboard -> /commander
    Commanders -> /commander/list
    Agent Tokens -> /commander/tokens
    Legacy Platform -> /command_platform
    Mnesia Database Info -> /mnesia
  Caddy
    Dashboard -> /caddy
    Configuration -> /caddy/config
    Server Control -> /caddy/server
    Runtime Config -> /caddy/runtime
    Metrics -> /caddy/metrics
    Logs -> /caddy/logs
  PKI
    CA List -> /pki/ca
    New CA -> /pki/ca/new
    Certificate List -> /pki/certificates
    Issue Certificate -> /pki/certificates/issue
    CSR Management -> /pki/csr
    Upload CSR -> /pki/csr/upload
    Search -> /pki/search
    Analytics -> /pki/analytics
  Storage
    File Browser -> /storage
    S3 Configuration -> /storage/config
```

## Navigation Behavior

- The left menu is the primary navigation after sign-in.
- Only the active branch opens by default.
- Parent branches open automatically when a child item is active.
- Active matching uses the current `active_menu` id when present, with route-derived fallback for pages that do not currently assign `active_menu`.
- Disabled placeholders are visible, non-clickable, and rendered with `aria-disabled`.
- Long menus scroll inside the sidebar.
- Main content scrolls independently from the sidebar.
- Existing routes and paths remain unchanged.

## Layout End State

After migration, authenticated admin pages should use one shell:

- Keep `Layouts.auth` for sign-in and sign-up.
- Make `Layouts.app` the only authenticated admin layout.
- Remove `Layouts.user`, `Layouts.aws`, `Layouts.storage`, and `Layouts.caddy` once their pages use `Layouts.app`.
- Remove embedded module-specific menu usage, including PKI's `PkiLeftMenu`, after its pages use the global menu.
- Keep the existing appbar unchanged while the left menu work is completed.

## Implementation Shape

Add:

- `GSMLG.AdminWeb.AdminMenu`
- `GSMLG.AdminWeb.Components.AdminNavigation` as the reusable global left-menu renderer

Update:

- `Layouts.app` to render the global left menu beside `@inner_block`
- Existing pages using `Layouts.user`, `Layouts.aws`, `Layouts.storage`, or `Layouts.caddy` to use `Layouts.app`
- PKI templates to remove direct `PkiLeftMenu` usage
- Outlier pages that currently render without a persistent left menu, including home, node management, command platform, GitHub, Mnesia, and Commander LiveViews

Do not:

- Change route paths
- Change the appbar before the left menu migration is complete
- Introduce DaisyUI or non-DuskMoon component libraries
- Add hardcoded color palette classes in new navigation code

## Validation

Run focused validation after implementation:

- `mix format`
- Compile admin web and dependent component code
- Ensure enabled menu routes exist
- Confirm disabled placeholders do not navigate
- Browser-check the admin shell at desktop width
- Verify active branch opening for Content, Cloud/AWS, Service/Caddy, Service/PKI, Service/Storage, and Dashboard
