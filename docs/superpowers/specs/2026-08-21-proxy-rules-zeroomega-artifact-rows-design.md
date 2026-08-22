# Proxy Rules ZeroOmega Artifact Rows Design

Date: 2026-08-21

## Status

Approved in conversation on 2026-08-21.

## Goal

Expose the existing parameterized ZeroOmega Switchy and PAC download URLs in
the authenticated `/proxy-rules` Artifacts table.

Both exports combine the two operational rule results:

- Proxy rules are the blacklist/match result.
- Direct rules are the whitelist/default result.
- Switchy renders Direct rules with `!` and Proxy rules normally.
- PAC renders both `directDomains` and `proxyDomains`, evaluating Direct first.

The table must therefore label both rows `Proxy + Direct`; neither row may be
presented as a Proxy-only or Direct-only artifact.

## Selected Approach

Append two parameterized rows to the existing six immutable artifact rows only
when a published generation exists:

| List | Format | URL |
| --- | --- | --- |
| Proxy + Direct | Switchy result | `/rules/zeroomega/switchy?mode=result&match_profile=squid&default_profile=direct` |
| Proxy + Direct | PAC | `/rules/zeroomega/pac?proxy=10.100.0.1:3128` |

The links use `GSMLG.Web.Endpoint.url/0`, matching the existing absolute public
download links.

Because both outputs depend on URL parameters and are rendered on request,
their Size and ETag cells display `Parameterized`. Their Last modified cell uses
the immutable generation's `compiled_at` value. The UI does not call the
exporter while loading the page, so it cannot mix metadata from separate Store
reads and does not add rendering work to the admin dashboard.

This was selected over:

- Rendering both exports during LiveView state loading, which would add CPU and
  separate Snapshot reads merely to populate Size and ETag.
- Adding parameter editors to the dashboard, which is outside the requested
  missing-link fix.

## UI and Accessibility

The existing table and column layout remain unchanged. Parameterized rows use
the same Download link styling and have precise labels:

```text
Download Proxy + Direct Switchy result
Download Proxy + Direct PAC
```

The table continues to show its existing empty state when no generation has
been published; it must not show links that would currently return 503.

## Testing

LiveView tests will prove:

- A ready generation renders eight rows: six fixed plus two parameterized.
- Both URLs are absolute and contain the exact approved parameters.
- Both rows are labeled `Proxy + Direct`.
- Size and ETag display `Parameterized`.
- Last modified uses the current generation compilation time.
- The not-ready state still renders no artifact table or download links.

## Non-Goals

- Persisting ZeroOmega parameters.
- Editing profile names or proxy endpoints from the dashboard.
- Pre-rendering parameterized artifacts into Snapshot metadata.
- Changing the public Switchy or PAC endpoints.
- Changing the six Raw, Squid, and Clash artifact rows.
