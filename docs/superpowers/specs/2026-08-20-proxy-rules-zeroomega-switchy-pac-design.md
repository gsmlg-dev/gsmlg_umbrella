# Proxy Rules ZeroOmega Switchy and PAC Export Design

Date: 2026-08-20

## Status

Approved in conversation on 2026-08-20.

This specification extends the domain-only Proxy Rules service described by
`2026-07-23-proxy-rules-full-v1-design.md`. It supersedes the earlier proposal
to add an AutoProxy 0.2.9 exporter. The second new format is a parameterized PAC
document whose proxy address is supplied by the caller.

## Goal

Publish two ZeroOmega-compatible views of the existing immutable Proxy Rules
generation:

- SwitchyOmega Conditions, in binary mode by default and optional result mode.
- PAC JavaScript with a caller-supplied proxy endpoint, such as
  `PROXY 10.100.0.1:3128`.

Both views must be deterministic for the same Proxy Rules generation and
canonical parameters. They reuse the current rule compiler, Store, persistence,
HTTP application, configuration, telemetry, and last-known-good behavior. They
do not create another database or mutable publication path.

## Existing Integration Points

The current `GSMLG.ProxyRules.Rule` model contains normalized domain-suffix
rules with `action: :proxy | :direct`. `GSMLG.ProxyRules.Domain` already owns
DNS trimming, lowercase conversion, trailing-dot removal, IDNA conversion, and
hostname validation.

`GSMLG.ProxyRules.Compiler` produces a complete immutable `Snapshot`.
`GSMLG.ProxyRules.Store` persists, restores, and atomically replaces that
snapshot through ETS. `GSMLG.Web.ProxyRulesController` already demonstrates
content-derived ETags, conditional GET, cache headers, and bounded 404/503
responses.

The new feature extends those boundaries rather than introducing a second rule
store, endpoint application, or release.

## Selected Approach

Use a compiled canonical policy plus parameterized pure renderers:

```text
current accepted rules
  -> adapt to ZeroOmega policy
  -> normalize
  -> validate policy invariants
  -> publish policy in immutable Snapshot
  -> validate request options
  -> render Switchy or PAC
  -> hash exact response bytes
  -> serve
```

The compiler builds and validates the ZeroOmega policy while it still has the
accepted folded rules. The policy is stored in the same versioned Snapshot as
the existing artifacts. Store publication therefore changes the Raw, Squid,
Clash, Switchy input policy, and PAC input policy as one atomic generation.

The request boundary reads `Store.current/0` exactly once. Rendering from that
immutable value is safe for concurrent readers and cannot observe a partially
updated generation. Request-time rendering is required because proxy endpoints
and result-mode profile names form an unbounded parameter space. The renderer
does not read source files, application state, clocks, or the network.

This was selected over:

- Pre-rendering an allowlist of configured proxy endpoints, which would prevent
  arbitrary valid URL parameters.
- Reconstructing a policy by parsing the existing Raw artifact, which would
  make one output format an accidental internal data contract.
- Rendering from local files during the request, which could observe partial
  external replacements and bypass last-known-good publication.

## Canonical ZeroOmega Policy

The exporter owns plain structs used only as immutable data:

```text
Policy {
  revision
  default_action
  rules
}

Rule {
  id
  priority
  enabled
  condition
  action
  note
  input_order
}

Action = direct | profile(profile_name)

Condition =
  domain_suffix(domain)
  | host_exact(host)
  | host_glob(pattern)
  | url_prefix(prefix)
  | url_glob(pattern)
  | url_regex(pattern)
  | cidr(network)
  | keyword(value)
```

The pure model and Switchy renderer support the complete condition union so
future sources can use result mode without replacing the exporter. The current
operational adapter emits only `domain_suffix` conditions because the existing
GFWList and local-source contract intentionally accepts only suffix domains.
This feature does not broaden those parsers.

For a request, the adapter maps current actions using validated options:

- `:proxy` becomes `profile(match_profile)`.
- `:direct` becomes `direct`, whose configured profile name is
  `default_profile`.

The operational policy orders Direct rules before Proxy rules, preserving the
existing documented Direct-before-Proxy conflict behavior. Within each
partition it keeps the compiler's deterministic domain order. The generic pure
normalizer otherwise sorts by ascending priority and preserves input order for
equal priorities.

## Normalization and Diagnostics

Normalization and validation are pure. They:

1. Remove disabled rules.
2. Trim textual fields.
3. Use `GSMLG.ProxyRules.Domain` for DNS and host canonicalization where the
   condition permits it.
4. Validate URLs, globs, regular expressions, and CIDRs without approximating
   unsupported conditions.
5. Reject NUL, CR, LF, control characters, and other line-injection input in
   patterns, notes, profile names, and proxy parameters.
6. Deduplicate identical normalized conditions with identical actions while
   retaining the first rule.
7. Produce stable ordering without consulting the current time.

Exporter diagnostics use a dedicated structured value:

```text
Diagnostic {
  severity
  code
  rule_id
  field
  message
}
```

Codes include `invalid_domain`, `invalid_url`, `invalid_regex`, `invalid_cidr`,
`line_injection`, `unsupported_condition`, `unsupported_action`,
`ambiguous_profile_name`, `conflicting_rule`, `missing_default_profile`, and
`invalid_proxy`.

Any error diagnostic fails compilation or the individual HTTP request. A failed
new compilation never replaces the last-known-good Snapshot. A bad query
parameter cannot modify or invalidate the published Snapshot.

## SwitchyOmega Conditions Export

### Endpoint and options

```text
GET  /rules/zeroomega/switchy
HEAD /rules/zeroomega/switchy
```

Accepted query parameters are:

- `mode=binary|result`, default `binary`.
- `match_profile=<name>`, default `squid`.
- `default_profile=<name>`, default `direct`.

Unknown parameters or duplicate values are rejected with HTTP 400. Profile
names are trimmed and must be non-empty. They reject control characters, CR,
LF, NUL, and ambiguous `+` sequences. Binary mode requires distinct match and
default profiles and rejects any policy action outside those two results.
Result mode may represent additional profile actions in the pure renderer,
although the current operational adapter supplies only the two configured
profiles.

### Binary mode

The body starts with:

```text
[SwitchyOmega Conditions]

```

Rules mapped to the match profile have no result suffix. Rules mapped to the
default profile begin with `!`. The current domain-only policy therefore emits:

```text
[SwitchyOmega Conditions]

!*.internal.example.com
*.google.com
*.github.com
```

The pure renderer implements the approved condition mappings:

| Condition | Switchy representation |
| --- | --- |
| `domain_suffix("example.com")` | `*.example.com` |
| `host_exact("example.com")` | `example.com` |
| `host_glob("api-*.example.com")` | `HostWildcard: api-*.example.com` |
| `url_prefix("https://example.com/api/")` | `UrlWildcard: https://example.com/api/*` |
| `url_glob("https://*.example.com/*")` | `UrlWildcard: https://*.example.com/*` |
| `url_regex("^https://example\\.com/")` | `UrlRegex: ^https://example\\.com/` |
| `cidr("10.0.0.0/8")` | `Ip: 10.0.0.0/8` |
| `keyword("example")` | `Keyword: example` |

A URL prefix gains one trailing `*` unless it already has one. A raw host glob
starting with `[`, `;`, `#`, `@`, `!`, or `+` uses the empty condition-type
escape `: <pattern>`. Comments use `;`; notes use `@note`. The modern format
never uses `#` as a comment.

### Result mode

Result mode emits `@with result`, appends `+<profile>` to non-default rules,
keeps default rules prefixed with `!`, and terminates the rule set with the
default catch-all:

```text
[SwitchyOmega Conditions]
@with result

*.google.com +squid
!*.internal.example.com

* +direct
```

All Switchy lines use CRLF, and every document ends with a final CRLF.

## Parameterized PAC Export

### Endpoint and options

```text
GET  /rules/zeroomega/pac?proxy=10.100.0.1:3128
HEAD /rules/zeroomega/pac?proxy=10.100.0.1:3128
```

`proxy` is required. It accepts a DNS hostname or IPv4 address followed by a
decimal port from 1 through 65535. A bracketed IPv6 literal followed by a port
is also accepted. The value is canonicalized before rendering. Schemes,
credentials, paths, query strings, fragments, whitespace, quotes, backslashes,
and control characters are rejected. Unknown or duplicate query parameters
return HTTP 400.

No proxy credentials or upstream configuration are included in the PAC body or
logs.

### PAC behavior

The generated document contains the caller's canonical endpoint exactly once
as a JavaScript string:

```javascript
var proxy = 'PROXY 10.100.0.1:3128';
```

`FindProxyForURL(url, host)` lowercases `host` and applies suffix matching with
an explicit label boundary. It does not use a substring-only suffix check that
could match `example.com.attacker.test` or `notexample.com`.

Evaluation order is:

1. A Local Direct or GFWList exclusion suffix returns `DIRECT`.
2. A GFWList or Local Proxy suffix returns the parameterized `proxy` value.
3. An unmatched host returns `DIRECT`.

The PAC generator does not select among multiple proxy servers, embed
authentication, fetch remote data, or execute matching on the Elixir server.
It exports JavaScript for ZeroOmega to execute.

Only `domain_suffix` is published through the operational PAC endpoint. If a
future canonical policy contains a condition that has no explicitly approved
PAC mapping, validation returns `unsupported_condition`; it is never silently
dropped or broadened.

The document uses CRLF and ends with a final CRLF. It contains no request-time
timestamp or nondeterministic value.

## HTTP Publication Contract

Both routes are public and use the existing Phoenix routing conventions. A
successful response includes:

- `Content-Type: text/plain; charset=utf-8` for Switchy.
- `Content-Type: application/x-ns-proxy-autoconfig; charset=utf-8` for PAC.
- `ETag: "sha256-<lowercase hex>"` calculated from the exact rendered bytes.
- `Cache-Control: no-cache`.
- `Last-Modified` from the immutable Snapshot compilation time.
- `X-Proxy-Rules-Generation` from the selected Snapshot.

Canonicalized equivalent parameters produce identical bodies and ETags. Query
parameter ordering does not affect output. `If-None-Match` supports strong,
weak, comma-separated, and `*` matching using the existing controller
semantics. A match returns 304 with no body. HEAD returns the same headers that
GET would return, including the GET content length, with no response body.

Missing or invalid parameters return a bounded plain-text 400 and are not
cached. No published Snapshot returns 503. Unexpected format identifiers or
routes retain the router's 404 behavior.

## Snapshot and Persistence Changes

`Snapshot` gains the normalized ZeroOmega policy required by both exporters.
The persistence validator includes that policy in its exact shape and size
limits. The artifact envelope version is incremented so an old pre-feature
artifact cannot be restored as though it contained the new policy. The remote
source-cache version remains unchanged, allowing the Coordinator to recompile
from the valid cached GFWList and current local sources after an upgrade.

The compiler validates the canonical policy for both required operational
formats before staging the complete Snapshot. This proves that every published
condition and action is representable by Switchy and PAC without needing a
request-specific proxy endpoint. The request boundary separately validates its
options and renders the final bytes. A policy validation error fails that
generation, emits structured bounded diagnostics, and retains the
last-known-good publication. It never publishes an empty substitute for an
invalid policy.

## Modules and Files

New pure modules under `apps/proxy_rules/lib/gsmlg/proxy_rules/zero_omega/`:

- `policy.ex` and `rule.ex` for canonical immutable data.
- `diagnostic.ex` for structured errors.
- `normalizer.ex` for the pure normalization and validation pipeline.
- `switchy.ex` for Switchy binary and result rendering.
- `pac.ex` for proxy-option validation and PAC rendering.
- `export.ex` for the public pure pipeline and rendered-result metadata.

Expected existing-file changes:

- `compiler.ex`, `snapshot.ex`, and `persistence.ex` to atomically publish and
  validate the canonical policy.
- `proxy_rules.ex` to expose a bounded exporter facade.
- `router.ex` plus a focused ZeroOmega controller in `gsmlg_web`.
- Proxy Rules and Web tests, golden fixtures, and `apps/proxy_rules/README.md`.

The implementation may combine very small modules where doing so preserves the
same pure boundaries and avoids one-function files. No new process is needed.

## Testing Strategy

Implementation follows red-green-refactor and adds:

- Normalizer unit tests for ordering, stable equal-priority input order,
  canonical DNS/IDNA, injection rejection, validation, and deduplication.
- Switchy unit and golden tests for every condition mapping, binary exclusions,
  sequential ordering, notes, result suffixes and catch-all, special-leading
  host-glob escaping, CRLF termination, profile validation, and determinism.
- PAC unit and golden tests for proxy validation, direct-before-proxy behavior,
  exact suffix boundaries, safe JavaScript generation, CRLF termination,
  deterministic output, and unsupported-condition rejection.
- Compiler, Snapshot, and persistence tests proving one complete generation,
  version migration, and rejection without replacing last-known-good output.
- Controller tests for GET 200, exact content types and bodies, stable ETags,
  canonical parameter equivalence, 304, HEAD, bounded 400/503, and no secret
  disclosure.
- Concurrent publication tests proving a reader receives one complete old or
  new document and never a mixed or partial document.
- Documentation assertions covering both endpoint URLs and their ZeroOmega UI
  settings.

The complete `apps/proxy_rules/test` suite and focused `gsmlg_web` ZeroOmega
controller tests must pass. Formatting, warnings-as-errors compilation for the
affected applications, and `git diff --check` are required before completion.

## ZeroOmega Configuration Documentation

The application documentation will show:

- SwitchyOmega Conditions URL:
  `/rules/zeroomega/switchy` for binary mode, or the result-mode URL with
  `mode=result&match_profile=squid&default_profile=direct`.
- PAC URL:
  `/rules/zeroomega/pac?proxy=10.100.0.1:3128`.
- The PAC URL belongs in ZeroOmega's PAC profile configuration; the Switchy URL
  belongs in a SwitchyOmega Conditions rule-list configuration.
- The supplied profile names must already exist in ZeroOmega. The server does
  not create ZeroOmega profiles or configure proxy authentication.

## Non-Goals

- AutoProxy 0.2.9 export.
- Full Adblock Plus parsing.
- Broadening GFWList or local-source accepted syntax.
- PAC execution inside the Elixir service.
- Proxy authentication or credentials in URLs or generated documents.
- Multiple PAC proxy targets, failover chains, or server selection.
- Editing ZeroOmega configuration or creating its profiles.
- A second persistent policy store, database, endpoint application, or release.
- Legacy Switchy `#BEGIN`, `[Wildcard]`, `[RegExp]`, or `#END` output.
