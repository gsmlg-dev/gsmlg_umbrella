# Admin mTLS Certificate Login Design

Date: 2026-08-29

## Status

Approved in conversation on 2026-08-29. This document records the approved
design for binding reverse-proxy-verified client certificates to admin users
and automatically creating browser sessions for later requests from those
certificates.

## Goal

Protect the production admin site with mTLS at an externally managed Caddy
reverse proxy while preserving the existing username/password login as the
one-time certificate enrollment and no-certificate fallback.

The proxy supplies these headers on requests carrying a verified client
certificate:

- `X-Client-Cert-Subject`
- `X-Client-Cert-Certificate-PEM`
- `X-Client-Cert-Email`

On first access with an unbound certificate, the admin sign-in page shows the
certificate details and requires the normal username and password. A
successful login permanently binds that certificate to the authenticated user.
Every later browser request with the same certificate automatically logs in the
same user.

## Scope

### Included

- Browser HTML and LiveView authentication in `gsmlg_admin_web`.
- Strict parsing of the three Caddy-provided certificate headers.
- Durable certificate-to-user bindings in `GSMLG.Accounts`.
- One-time binding after successful password authentication.
- Guardian session creation and replacement from an existing binding.
- Certificate details on the existing sign-in page.
- Certificate-aware sign-out behavior.
- TOML configuration for enabling the behavior in production.
- Focused context, plug, controller, LiveView/session, template, and
  configuration tests.

### Excluded

- Caddy configuration, certificate authority management, certificate issuance,
  and mTLS verification. The reverse proxy is another application.
- JSON API, MCP, Commander, bearer-token, and non-browser socket authentication
  changes.
- Matching users by certificate email or subject.
- Certificate-binding administration, reassignment, revocation, or deletion UI.
- User self-service certificate rotation.
- Release, deployment, and production proxy changes.

## Trust Boundary and Caddy Header Contract

Caddy is responsible for validating the client certificate chain and for
overwriting all three upstream headers. Phoenix does not repeat CA validation;
it validates only that the asserted certificate value is structurally usable.

Production must keep the Phoenix admin port private to the proxy network. A
client that can reach Phoenix directly and set these headers can otherwise
impersonate a bound certificate. Allowing password login when the headers are
absent does not relax this network requirement.

The expected Caddy placeholder mapping is:

| Header | Caddy value |
|---|---|
| `X-Client-Cert-Subject` | `{http.request.tls.client.subject}` |
| `X-Client-Cert-Certificate-PEM` | `{http.request.tls.client.certificate_der_base64}` |
| `X-Client-Cert-Email` | `{http.request.tls.client.san.emails.0}` |

The certificate header retains the requested historical name, but its value is
base64-encoded DER rather than literal PEM. Caddy's
`certificate_pem` placeholder contains real newline characters and cannot be
safely forwarded as an HTTP header. Phoenix decodes the DER and reconstructs
the PEM text for display.

References:

- [Caddyfile placeholders](https://caddyserver.com/docs/caddyfile/concepts)
- [Caddy certificate placeholder implementation](https://github.com/caddyserver/caddy/blob/master/modules/caddyhttp/replacer.go)
- [Caddy DER-base64 certificate placeholder](https://github.com/caddyserver/caddy/pull/4241)

## Configuration

Add this option to the existing `[admin_web]` TOML section:

```toml
client_certificate_auth = false
```

The default is `false`. Production explicitly sets it to `true`. When disabled,
the application ignores the three certificate headers and preserves all
existing authentication behavior.

The option follows the repository's normal configuration path:

1. `GSMLG.Config.Schema` validates it as a boolean.
2. `GSMLG.Config.Setup.setup_admin_web/1` adds it to the admin endpoint
   application environment.
3. The default TOML documents the disabled value.
4. Tests enable it explicitly when exercising certificate behavior.

## Certificate Binding Model

Add a `user_client_certificates` table owned by `GSMLG.Accounts`.

Each row contains:

- An application-generated UUID primary key.
- A string `user_id` foreign key referencing `users.id`, with dependent rows
  removed if the user is deleted.
- A required 64-character lowercase hexadecimal SHA-256 `fingerprint`.
- The required leaf certificate DER bytes.
- The proxy-reported subject.
- The proxy-reported email.
- Normal inserted and updated timestamps.

The fingerprint is computed locally over the decoded DER bytes. It is globally
unique and is the only field used to find a binding. Subject and email are
display and audit metadata only.

A user may own multiple certificate bindings. One certificate can belong to
only one user. The unique fingerprint constraint is the authoritative guard
against concurrent enrollment and reassignment.

The login flow exposes no update, reassignment, or deletion operation for a
binding. Once inserted, a certificate always resolves to that user for as long
as both records exist.

## Component Responsibilities

### Certificate header parser

A focused `gsmlg_admin_web` module reads and validates proxy assertions. It:

1. Requires exactly one value for each of the three headers.
2. Strictly base64-decodes the certificate header.
3. Rejects empty certificates and decoded DER larger than 16 KiB.
4. Parses the value as one X.509 certificate.
5. Computes the lowercase SHA-256 DER fingerprint.
6. Reconstructs canonical PEM for rendering.
7. Returns one immutable certificate presentation containing DER, fingerprint,
   PEM, subject, and email.

Missing, duplicate, incomplete, oversized, malformed-base64, or malformed-X.509
input is treated as no usable client certificate. The parser never trusts a
fingerprint, user identifier, subject, or email supplied separately by the
client.

### Accounts context

`GSMLG.Accounts` owns binding persistence and lookup. Its public boundary must
support:

- Looking up the user and binding by a fingerprint.
- Binding a parsed certificate to an authenticated user.
- Treating a repeated bind of the same certificate to the same user as
  idempotent success.
- Rejecting an attempt to bind a fingerprint already owned by another user.

Database uniqueness, not a prior lookup alone, resolves concurrent enrollment.
If another request binds the certificate between lookup and insert, the
authoritative row determines its owner.

### Browser authentication plug

A browser-only plug runs after Guardian verifies and loads any existing session
and before `Guardian.Plug.EnsureAuthenticated` protects admin pages.

When certificate authentication is disabled, it performs no work.

When enabled:

- A bound certificate signs in its bound user. If an existing Guardian session
  belongs to another user, the certificate owner replaces it.
- A valid unbound certificate clears any existing Guardian authentication and
  marks the request for enrollment. A stale password session cannot silently
  bind a new certificate.
- Missing or unusable certificate headers preserve an ordinary password-created
  session.
- Missing or unusable headers clear a session previously marked as
  certificate-created, so removing the client certificate ends certificate
  access and falls back to the password login page.

The session records a non-authoritative authentication-method marker so the UI,
sign-out controller, and LiveView connection can distinguish certificate and
password sessions. Every browser request re-establishes the marker from the
current trusted headers; the marker never authenticates a user by itself.

### Auth controller and template

The existing `/sign_in` actions remain the enrollment surface.

For an unbound certificate, the GET page displays:

- A clear notice that username/password login will permanently bind the shown
  certificate.
- Certificate subject.
- Certificate email.
- Canonical PEM in a read-only, selectable, preformatted control.
- The existing username/password form.

The POST action reads the certificate again from the request headers. It never
accepts certificate bytes, fingerprint, subject, or email from hidden form
fields.

After successful password authentication, the controller atomically binds the
certificate before creating the Guardian session. A failed password or failed
binding creates neither a binding nor an authenticated session. An ordinary
login without a usable certificate continues to create a password session
without a binding.

When a bound certificate reaches `/sign_in`, its certificate owner wins and
submitted credentials are not allowed to replace that identity.

## Request Flows

### First request with an unbound certificate

1. Caddy validates the certificate and overwrites the three headers.
2. Phoenix parses the DER and computes its fingerprint.
3. Accounts finds no binding.
4. Any existing Guardian login is cleared.
5. A protected page redirects to `/sign_in` through the existing Guardian error
   handler.
6. `/sign_in` shows the subject, email, PEM, permanence notice, and credential
   form.
7. Successful credentials bind the certificate and sign in that user.
8. The current successful-login destination remains unchanged.

### Later request with a bound certificate

1. Phoenix computes the fingerprint from the current DER header.
2. Accounts loads its binding and user.
3. Phoenix establishes or refreshes that user's Guardian browser session.
4. The requested protected page proceeds without showing the login form.

This rule applies even if the browser cookie previously represented another
user. Certificate ownership is authoritative whenever a bound certificate is
present.

### Request without usable certificate headers

- A normal password session continues unchanged.
- A certificate-created session is cleared and the next protected access uses
  the ordinary password login flow.
- A visitor without a session sees the ordinary password login flow.
- No certificate binding is created.

### Concurrent binding conflict

If a certificate becomes bound after the request was classified as unbound,
the unique constraint prevents a second owner. The application reloads the
authoritative binding. A same-user result is idempotent success; a different
owner prevents the credential-selected user from being signed in. On the next
request, the bound certificate logs in its authoritative owner.

## LiveView and Session Continuity

The initial LiveView HTTP request uses the browser plug and Guardian session in
the normal way. Connected mounts also validate a certificate-created session
marker against the current connection headers made available by the existing
endpoint `:x_headers` connect info.

If a certificate-created LiveView reconnects without a usable certificate, it
must not restore the marked user from the cookie. It redirects to `/sign_in`,
where password login remains available. Existing already-connected sockets are
not proactively terminated; mTLS connection lifetime and termination remain
the proxy's responsibility.

## Sign-out Behavior

Password-created sessions retain the existing sign-out behavior.

Certificate-created sessions do not present a sign-out control. Any direct
browser request to the sign-out route keeps the certificate owner authenticated
and explains that removing the client certificate ends access. This avoids a
redirect loop in which sign-out is immediately undone by the same certificate.

The authenticated JSON API sign-out route retains its existing behavior because
certificate authentication is browser-only.

## Error Handling and Observability

Certificate parsing failures degrade to the approved password flow. They do not
produce a binding or automatic login. The sign-in page may state that no usable
certificate was received, but it must not expose decoder internals or treat
subject/email as proof of identity.

Enrollment failures keep the sign-in page available and show an actionable
generic error. A cross-user uniqueness conflict never reassigns the certificate
and never signs in the credential-selected user.

Telemetry may record:

- Successful binding with user ID, fingerprint, and subject.
- Automatic certificate login with user ID and fingerprint.
- Malformed certificate assertion by category.
- Cross-user binding conflict with fingerprint and involved user IDs.

Telemetry and application logs must never include the DER bytes, reconstructed
PEM, password, Guardian token, or complete raw request headers.

## Verification

### Accounts tests

- Binding persists DER, fingerprint, subject, email, and user ownership.
- Fingerprints are unique across users.
- Rebinding the same certificate to the same user is idempotent.
- Rebinding it to another user fails without changing ownership.
- One user may own multiple certificates.
- Deleting a user removes dependent bindings.

### Parser and browser plug tests

- Valid Caddy DER-base64 is parsed and reconstructed as PEM.
- Missing, partial, duplicate, malformed, oversized, and non-X.509 headers
  produce no usable certificate.
- Headers are ignored when the feature is disabled.
- A bound fingerprint signs in its owner.
- A bound fingerprint replaces a conflicting Guardian session.
- An unbound certificate clears an existing password session for enrollment.
- Removing the certificate clears a certificate-created session but preserves a
  password-created session.

### Controller and rendering tests

- Unbound certificate access renders subject, email, PEM, and the permanence
  notice with the existing credential form.
- Subject and email mismatches do not affect successful enrollment.
- Successful credentials bind before sign-in.
- Failed credentials create no binding.
- Login without certificate headers remains supported and creates no binding.
- A direct certificate-session sign-out remains authenticated and explains how
  access ends.
- Password-session sign-out remains unchanged.

### LiveView and isolation tests

- Initial and reconnected LiveViews accept a current bound certificate session.
- A certificate-created reconnect without certificate assertions cannot reuse
  the marked cookie.
- JSON API, MCP, Commander, bearer-token, and socket authentication paths do not
  acquire certificate auto-login behavior.

### Configuration tests

- The TOML schema accepts and defaults `client_certificate_auth` correctly.
- Admin endpoint setup propagates the value.
- Disabled configuration preserves the existing authentication baseline.

Only focused `gsmlg`, `gsmlg_admin_web`, and `gsmlg_config` tests for this
feature are required by the implementation plan. Browser verification should
confirm the read-only PEM presentation, keyboard access, and certificate-aware
sign-out messaging without changing the established admin authentication visual
language.
