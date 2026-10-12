# GaoNote sync v1 ingress

The receiver is disabled by default. Provision a peer with
`GSMLG.GaoNote.Sync.register_peer/1`, binding its certificate's SHA-256 fingerprint
(64 lowercase hexadecimal characters), node UUID, GaoNote actor, and authorized
selectors. The client node UUID must match this registered node; browser sessions,
query parameters and forwarded source addresses confer no authority.

```toml
[note_sync]
enabled = true
trusted_proxy_ips = ["127.0.0.1", "::1"]
max_blob_bytes = 536870912
```

`trusted_proxy_ips` lists exact TCP peer addresses, not CIDRs or forwarded client
addresses. Supply only addresses of the proxy that verifies client certificates.
The proxy must overwrite the identity header, including removing duplicate
client-supplied values. The receiver requires one lowercase fingerprint header.
No longpoll transport is mounted; only Phoenix V2 JSON text frames are accepted.

Example Caddy configuration (adapt paths and upstream listener to your host):

```caddyfile
admin.gsmlg.org {
    tls {
        client_auth {
            mode require_and_verify
            trust_pool file {
                pem_file /etc/caddy/note-sync-client-ca.pem
            }
        }
    }

    @note_sync path /note-sync/websocket
    reverse_proxy @note_sync 127.0.0.1:4111 {
        header_up -X-Note-Sync-Client-Fingerprint
        header_up X-Note-Sync-Client-Fingerprint {http.request.tls.client.fingerprint}
    }
}
```

A site-wide client authentication policy also applies to the site's other routes.
Use a dedicated ingress listener/hostname if those routes require a different
certificate policy. Preserve the protocol endpoint expected by provisioned clients.
Validate the template against the deployed Caddy version and inspect the actual
fingerprint format before enablement; the receiver never normalizes an unverified
identity string.

The backend listener must be private and firewalled against direct client access.
A header from an untrusted TCP peer fails closed. A process able to connect from
an allowlisted proxy host can impersonate that proxy; a fingerprint header alone
cannot distinguish those processes. Enforce host/network isolation and protect
proxy configuration and the client CA. Never publish port 4111 directly as an
alternative path to `/note-sync`.

Enablement requires positive and negative live certificate tests through the
real ingress, including unregistered/revoked certificates, absent certificates,
spoofed/duplicate headers, untrusted backend TCP peers, and wrong selectors/node
IDs. Local channel or WebSocket tests establish wire behavior only; they do not
qualify the deployed TLS ingress or firewall.

Transfers expire after ten seconds without progress. Temporary assembly files and
read leases are released on channel exit; durable pending snapshots survive.
Definitive `validation_failed`/`catalog_conflict` rejections retain pending work
and are cached by event ID across reconnects; a new snapshot or operator retry
makes the note eligible again. Oversized notes remain pending while other notes
continue. ACKs release leases only after full durable descriptor matching.
