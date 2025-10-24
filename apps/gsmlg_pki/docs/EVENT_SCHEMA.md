# PKI Event Schema Documentation

## Overview

The GSMLG PKI system uses event sourcing to maintain an immutable audit trail of all certificate operations. Events are stored in CouchDB and represent the complete state history of the Certificate Authority.

## Design Principles

1. **Immutability**: Events are never modified or deleted
2. **Append-Only**: New events are always added to the end
3. **Complete History**: Every operation is an event
4. **State Reconstruction**: Current state is derived from event replay
5. **Audit Trail**: Perfect audit trail by design

## Event Structure

All events follow a consistent structure:

```elixir
%{
  "_id" => "event:#{UUID}",
  "type" => "pki_event",
  "event_type" => :ca_initialized | :certificate_issued | :certificate_revoked | :crl_generated,
  "timestamp" => "2025-10-24T12:00:00.000000Z",
  "sequence" => 12345,  # Monotonic counter
  "ca_id" => "ca:root",  # CA identifier
  "metadata" => %{...},  # Event-specific data
  "actor" => "admin@example.com",  # Who performed the action
  "correlation_id" => "req-abc123"  # Request tracking
}
```

## Event Types

### 1. CA Initialized

Records the creation of a new Certificate Authority.

```elixir
%{
  "event_type" => :ca_initialized,
  "metadata" => %{
    "ca_id" => "ca:root",
    "subject" => "/CN=GSMLG Root CA/O=GSMLG/C=US",
    "key_type" => "rsa",
    "key_size" => 4096,
    "validity_days" => 7300,  # 20 years
    "certificate_der" => <<...>>,  # DER-encoded certificate
    "public_key_der" => <<...>>,   # DER-encoded public key
    "ski" => "ABC123...",  # Subject Key Identifier (hex)
    "serial" => 1,
    "not_before" => "2025-01-01T00:00:00Z",
    "not_after" => "2045-01-01T00:00:00Z"
  }
}
```

### 2. Certificate Issued

Records the issuance of a new certificate.

```elixir
%{
  "event_type" => :certificate_issued,
  "metadata" => %{
    "serial" => 12345,
    "subject" => "/CN=example.com/O=Example Inc",
    "issuer_ca_id" => "ca:root",
    "issuer_subject" => "/CN=GSMLG Root CA",
    "certificate_type" => "server",  # server, client, intermediate_ca
    "template" => "server",  # Template used
    "key_type" => "ec",
    "curve" => "secp256r1",
    "validity_days" => 365,
    "not_before" => "2025-10-24T00:00:00Z",
    "not_after" => "2026-10-24T00:00:00Z",
    "certificate_der" => <<...>>,
    "subject_alternative_names" => ["example.com", "www.example.com"],
    "key_usage" => ["digitalSignature", "keyEncipherment"],
    "extended_key_usage" => ["serverAuth"],
    "ski" => "DEF456...",
    "aki" => "ABC123...",  # Authority Key Identifier
    "csr_fingerprint" => "sha256:...",  # If issued from CSR
    "auto_renew" => false
  }
}
```

### 3. Certificate Revoked

Records the revocation of a certificate.

```elixir
%{
  "event_type" => :certificate_revoked,
  "metadata" => %{
    "serial" => 12345,
    "ca_id" => "ca:root",
    "reason" => "keyCompromise",  # RFC 5280 revocation reasons
    "revocation_date" => "2025-10-24T12:00:00Z",
    "invalidity_date" => nil,  # Optional: when compromise occurred
    "subject" => "/CN=example.com",
    "issuer_subject" => "/CN=GSMLG Root CA"
  }
}
```

**Valid Revocation Reasons:**
- `unspecified` (0)
- `keyCompromise` (1)
- `cACompromise` (2)
- `affiliationChanged` (3)
- `superseded` (4)
- `cessationOfOperation` (5)
- `certificateHold` (6) - reversible
- `removeFromCRL` (8) - only for certificateHold
- `privilegeWithdrawn` (9)
- `aACompromise` (10)

### 4. CRL Generated

Records the generation of a Certificate Revocation List.

```elixir
%{
  "event_type" => :crl_generated,
  "metadata" => %{
    "ca_id" => "ca:root",
    "crl_number" => 42,
    "this_update" => "2025-10-24T12:00:00Z",
    "next_update" => "2025-10-31T12:00:00Z",
    "revoked_count" => 5,
    "crl_der" => <<...>>,
    "crl_size_bytes" => 2048,
    "distribution_url" => "http://crl.gsmlg.net/root.crl"
  }
}
```

### 5. Certificate Validated

Records chain validation attempts (for monitoring/debugging).

```elixir
%{
  "event_type" => :certificate_validated,
  "metadata" => %{
    "serial" => 12345,
    "subject" => "/CN=example.com",
    "validation_result" => "valid",  # valid, expired, revoked, invalid_chain
    "chain_length" => 3,
    "trust_anchor" => "/CN=GSMLG Root CA",
    "validation_time_ms" => 12,
    "checks_performed" => ["chain", "expiry", "revocation", "key_usage"],
    "policy_oid" => nil
  }
}
```

### 6. Certificate Renewed

Records automatic or manual certificate renewal.

```elixir
%{
  "event_type" => :certificate_renewed,
  "metadata" => %{
    "old_serial" => 12345,
    "new_serial" => 12346,
    "subject" => "/CN=example.com",
    "renewal_type" => "automatic",  # automatic, manual
    "days_before_expiry" => 30,
    "preserved_fields" => ["subject", "san", "key_usage"]
  }
}
```

## CouchDB Design Documents

### Views for Event Queries

```javascript
// View: events_by_ca
{
  "_id": "_design/pki",
  "views": {
    "events_by_ca": {
      "map": "function(doc) {
        if (doc.type === 'pki_event') {
          emit([doc.ca_id, doc.sequence], doc);
        }
      }"
    },
    "events_by_type": {
      "map": "function(doc) {
        if (doc.type === 'pki_event') {
          emit([doc.event_type, doc.timestamp], doc);
        }
      }"
    },
    "certificates_by_serial": {
      "map": "function(doc) {
        if (doc.type === 'pki_event' &&
            (doc.event_type === 'certificate_issued' ||
             doc.event_type === 'certificate_revoked')) {
          emit(doc.metadata.serial, doc);
        }
      }"
    },
    "active_certificates": {
      "map": "function(doc) {
        if (doc.type === 'pki_event' && doc.event_type === 'certificate_issued') {
          var notAfter = new Date(doc.metadata.not_after);
          var now = new Date();
          if (notAfter > now) {
            emit([doc.ca_id, doc.metadata.not_after], {
              serial: doc.metadata.serial,
              subject: doc.metadata.subject,
              not_after: doc.metadata.not_after
            });
          }
        }
      }",
      "reduce": "_count"
    },
    "revoked_certificates": {
      "map": "function(doc) {
        if (doc.type === 'pki_event' && doc.event_type === 'certificate_revoked') {
          emit([doc.ca_id, doc.metadata.serial], {
            serial: doc.metadata.serial,
            reason: doc.metadata.reason,
            revocation_date: doc.metadata.revocation_date
          });
        }
      }"
    },
    "expiring_soon": {
      "map": "function(doc) {
        if (doc.type === 'pki_event' && doc.event_type === 'certificate_issued') {
          var notAfter = new Date(doc.metadata.not_after);
          var now = new Date();
          var thirtyDaysFromNow = new Date(now.getTime() + (30 * 24 * 60 * 60 * 1000));
          if (notAfter > now && notAfter < thirtyDaysFromNow) {
            emit(doc.metadata.not_after, {
              serial: doc.metadata.serial,
              subject: doc.metadata.subject,
              not_after: doc.metadata.not_after,
              days_remaining: Math.floor((notAfter - now) / (24 * 60 * 60 * 1000))
            });
          }
        }
      }"
    }
  }
}
```

### Mango Indexes

```elixir
# Index for querying by serial number
%{
  "index" => %{
    "fields" => ["metadata.serial"]
  },
  "name" => "serial-index",
  "type" => "json"
}

# Index for querying by CA and timestamp
%{
  "index" => %{
    "fields" => ["ca_id", "timestamp"]
  },
  "name" => "ca-timestamp-index",
  "type" => "json"
}

# Index for querying revoked certificates
%{
  "index" => %{
    "fields" => ["event_type", "metadata.serial", "timestamp"]
  },
  "name" => "revocation-index",
  "type" => "json"
}
```

## Event Replay Patterns

### Get Current Certificate State

```elixir
def get_certificate_state(serial) do
  # Get all events for this certificate
  events = query_events_by_serial(serial)

  # Replay events to build current state
  Enum.reduce(events, %{status: :unknown}, fn event, state ->
    case event["event_type"] do
      "certificate_issued" ->
        %{
          status: :active,
          serial: serial,
          subject: event["metadata"]["subject"],
          not_before: event["metadata"]["not_before"],
          not_after: event["metadata"]["not_after"],
          certificate_der: event["metadata"]["certificate_der"]
        }

      "certificate_revoked" ->
        Map.merge(state, %{
          status: :revoked,
          revocation_reason: event["metadata"]["reason"],
          revoked_at: event["metadata"]["revocation_date"]
        })

      _ -> state
    end
  end)
end
```

### Build CRL from Events

```elixir
def build_crl_from_events(ca_id) do
  # Query all revocation events for this CA
  revocations = query_revocations(ca_id)

  # Convert to CRL entries
  entries = Enum.map(revocations, fn event ->
    %{
      serial: event["metadata"]["serial"],
      revocation_date: parse_datetime(event["metadata"]["revocation_date"]),
      reason: event["metadata"]["reason"]
    }
  end)

  # Generate CRL using existing GSMLG.PKI.CRL module
  GSMLG.PKI.CRL.new(entries, issuer_cert, issuer_key)
end
```

## Performance Considerations

1. **Event Indexing**: Use CouchDB indexes for fast queries by serial, CA, timestamp
2. **Caching**: Cache frequently accessed certificate states in ETS
3. **Batch Queries**: Use `_all_docs` with `include_docs=true` for bulk operations
4. **Compaction**: CouchDB auto-compaction keeps database size manageable
5. **Replication**: Use CouchDB replication for backup and HA

## Security Considerations

1. **Event Immutability**: CouchDB update validation functions prevent event modification
2. **Authentication**: Require authentication for all CouchDB operations
3. **Authorization**: Use CouchDB security documents to restrict access
4. **Audit**: Events themselves provide complete audit trail
5. **Encryption**: Store sensitive data (private keys) separately, NOT in events

## Event Retention

- **Active Certificates**: Keep all events
- **Expired Certificates**: Keep events for 1 year after expiration
- **Revoked Certificates**: Keep events for 10 years (compliance requirement)
- **Validation Events**: Keep for 90 days (optional, for debugging)

## Migration Strategy

When upgrading event schema versions:

1. Add `schema_version` field to events
2. Support reading old versions
3. Write new versions
4. Optionally migrate old events in background
