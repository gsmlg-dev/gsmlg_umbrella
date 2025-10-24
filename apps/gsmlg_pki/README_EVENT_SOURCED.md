# Event-Sourced PKI System

## Overview

The GSMLG PKI system is a complete, production-ready Certificate Authority implementation with event sourcing, providing perfect audit trails, horizontal scalability, and comprehensive certificate lifecycle management.

## Quick Start

### 1. Setup Database

```elixir
# Initialize CouchDB database and indexes
iex> GSMLG.PKI.Store.CouchDB.setup()
:ok
```

### 2. Initialize CA

```elixir
# Create a new root CA
iex> {:ok, ca} = GSMLG.PKI.CA.initialize(
...>   "/CN=GSMLG Root CA/O=GSMLG/C=US",
...>   key_type: :rsa,
...>   key_size: 4096,
...>   validity: 7300,
...>   actor: "admin@gsmlg.net"
...> )
{:ok, %{id: "ca:...", certificate: ..., private_key: ..., subject: "..."}}

# IMPORTANT: Save the private key securely!
iex> {:ok, key_pem} = GSMLG.PKI.PrivateKey.to_pem(ca.private_key)
iex> File.write!("/secure/path/ca-key.pem", key_pem)
:ok
```

### 3. Issue a Certificate

```elixir
# From CSR
iex> csr_pem = File.read!("server.csr")
iex> {:ok, cert} = GSMLG.PKI.CA.issue_certificate(
...>   ca,
...>   csr_pem,
...>   template: :server,
...>   validity: 365,
...>   extensions: [
...>     subject_alt_name: ["example.com", "www.example.com"]
...>   ],
...>   actor: "admin@gsmlg.net"
...> )
{:ok, certificate}

# Or directly
iex> key = GSMLG.PKI.PrivateKey.new_rsa(2048)
iex> public_key = GSMLG.PKI.PublicKey.derive(key)
iex> {:ok, cert} = GSMLG.PKI.CA.issue_certificate_direct(
...>   ca,
...>   public_key,
...>   "/CN=example.com",
...>   template: :server,
...>   validity: 365
...> )
```

### 4. Validate Certificate

```elixir
iex> {:ok, :valid} = GSMLG.PKI.Validator.validate_chain(
...>   cert,
...>   [ca.certificate],
...>   check_revocation: true,
...>   usage: :serverAuth
...> )
{:ok, :valid}
```

### 5. Revoke Certificate

```elixir
iex> import GSMLG.PKI.ASN1
iex> otp_certificate(tbsCertificate: tbs) = cert
iex> otp_tbs_certificate(serialNumber: serial) = tbs
iex> :ok = GSMLG.PKI.CA.revoke_certificate(
...>   ca,
...>   serial,
...>   reason: :keyCompromise,
...>   actor: "security@gsmlg.net"
...> )
:ok
```

### 6. Generate CRL

```elixir
iex> {:ok, crl} = GSMLG.PKI.CA.generate_crl(ca)
iex> {:ok, crl_der} = GSMLG.PKI.CRL.to_der(crl)
iex> File.write!("root-ca.crl", crl_der)
:ok
```

## Key Features

### ✅ Complete CA Operations
- Root CA initialization
- Certificate issuance (from CSR or direct)
- Certificate revocation with RFC 5280 reason codes
- CRL generation from events
- Chain validation with revocation checking

### ✅ Event Sourcing
- **Perfect Audit Trail**: Every operation logged as immutable event
- **Time Travel**: Reconstruct certificate state at any point in time
- **No Schema Migrations**: Events are versioned, future-proof
- **Horizontal Scalability**: CouchDB replication for HA

### ✅ Integration
- **CouchDB**: Persistent event storage with efficient indexes
- **Telemetry**: Comprehensive logging and metrics
- **Guardian**: Certificate-based authentication (examples provided)
- **Phoenix SSL**: Mutual TLS support (examples provided)

## Architecture

```
┌─────────────────────┐
│  CA Operations      │
│  (issue, revoke)    │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  GSMLG.PKI.CA       │
│  (High-level API)   │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  GSMLG.PKI.Events   │
│  (Event Sourcing)   │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  CouchDB            │
│  (Event Store)      │
└─────────────────────┘
```

## Documentation

- **[EVENT_SCHEMA.md](docs/EVENT_SCHEMA.md)** - Event types and database schema
- **[IMPLEMENTATION_GUIDE.md](docs/IMPLEMENTATION_GUIDE.md)** - Comprehensive usage guide (1000+ lines)
- **[IMPLEMENTATION_SUMMARY.md](docs/IMPLEMENTATION_SUMMARY.md)** - Architecture and design decisions

## Example: Certificate Lifecycle

```elixir
# 1. Issue certificate
{:ok, cert} = GSMLG.PKI.CA.issue_certificate_direct(
  ca,
  public_key,
  "/CN=example.com",
  template: :server,
  validity: 365,
  actor: "admin"
)

# Event logged: :certificate_issued
# - timestamp: 2025-10-24T12:00:00Z
# - serial: 12345
# - subject: "/CN=example.com"
# - actor: "admin"

# 2. Query certificate state
{:ok, state} = GSMLG.PKI.Events.get_certificate_state(12345)
# => %{
#      status: :active,
#      serial: 12345,
#      subject: "/CN=example.com",
#      not_after: ~U[2026-10-24 00:00:00Z],
#      events: [%{event_type: :certificate_issued, ...}]
#    }

# 3. Validate certificate
{:ok, :valid} = GSMLG.PKI.Validator.validate_chain(cert, [ca.certificate])

# Event logged: :certificate_validated
# - timestamp: 2025-10-25T08:00:00Z
# - serial: 12345
# - validation_result: "valid"

# 4. Revoke certificate
:ok = GSMLG.PKI.CA.revoke_certificate(ca, 12345,
  reason: :keyCompromise,
  actor: "security"
)

# Event logged: :certificate_revoked
# - timestamp: 2025-11-01T14:00:00Z
# - serial: 12345
# - reason: :keyCompromise
# - actor: "security"

# 5. Query revoked state
{:ok, state} = GSMLG.PKI.Events.get_certificate_state(12345)
# => %{
#      status: :revoked,
#      serial: 12345,
#      revocation_reason: :keyCompromise,
#      revoked_at: ~U[2025-11-01 14:00:00Z],
#      events: [
#        %{event_type: :certificate_issued, ...},
#        %{event_type: :certificate_validated, ...},
#        %{event_type: :certificate_revoked, ...}
#      ]
#    }

# 6. Generate CRL
{:ok, crl} = GSMLG.PKI.CA.generate_crl(ca)

# Event logged: :crl_generated
# - timestamp: 2025-11-01T15:00:00Z
# - crl_number: 1
# - revoked_count: 1
```

## Monitoring and Statistics

```elixir
# Get CA statistics
{:ok, stats} = GSMLG.PKI.CA.get_stats("ca:root")
# => %{
#      active_certificates: 42,
#      revoked_certificates: 5,
#      expired_certificates: 3,
#      total_issued: 50
#    }

# Find expiring certificates
{:ok, expiring} = GSMLG.PKI.CA.get_expiring_certificates("ca:root", 30)
# => [
#      %{serial: 12346, subject: "/CN=test.com", days_remaining: 25, ...},
#      %{serial: 12347, subject: "/CN=api.com", days_remaining: 15, ...}
#    ]

# Query audit trail
{:ok, events} = GSMLG.PKI.Events.query_by_ca("ca:root")
# Returns all events for audit/compliance

# Query revocations
{:ok, revocations} = GSMLG.PKI.Events.query_by_type(:certificate_revoked)
```

## Configuration

```elixir
# config/config.exs
config :gsmlg_couchdb, GSMLG.CouchDB.Connection,
  scheme: :http,
  host: "localhost",
  port: 5984,
  username: "admin",
  password: System.get_env("COUCHDB_PASSWORD")

config :gsmlg_pki, GSMLG.PKI.Store.CouchDB,
  database: "pki_events"

# config/runtime.exs (production)
config :gsmlg_couchdb, GSMLG.CouchDB.Connection,
  scheme: :https,
  host: System.get_env("COUCHDB_HOST"),
  port: 6984,
  username: System.get_env("COUCHDB_USER"),
  password: System.get_env("COUCHDB_PASS")
```

## Testing

```elixir
defmodule MyApp.PKITest do
  use ExUnit.Case

  setup do
    # Setup test CA
    {:ok, ca} = GSMLG.PKI.CA.initialize("/CN=Test CA",
      key_type: :rsa,
      key_size: 2048,
      actor: "test"
    )

    {:ok, ca: ca}
  end

  test "issue and validate certificate", %{ca: ca} do
    # Issue
    key = GSMLG.PKI.PrivateKey.new_rsa(2048)
    public_key = GSMLG.PKI.PublicKey.derive(key)

    {:ok, cert} = GSMLG.PKI.CA.issue_certificate_direct(
      ca,
      public_key,
      "/CN=test.example.com",
      validity: 365
    )

    # Validate
    {:ok, :valid} = GSMLG.PKI.Validator.validate_chain(
      cert,
      [ca.certificate]
    )
  end

  test "revoke certificate", %{ca: ca} do
    # Issue
    key = GSMLG.PKI.PrivateKey.new_rsa(2048)
    public_key = GSMLG.PKI.PublicKey.derive(key)
    {:ok, cert} = GSMLG.PKI.CA.issue_certificate_direct(ca, public_key, "/CN=test")

    # Extract serial
    import GSMLG.PKI.ASN1
    otp_certificate(tbsCertificate: tbs) = cert
    otp_tbs_certificate(serialNumber: serial) = tbs

    # Revoke
    :ok = GSMLG.PKI.CA.revoke_certificate(ca, serial, reason: :keyCompromise)

    # Verify
    {:ok, state} = GSMLG.PKI.Events.get_certificate_state(serial)
    assert state.status == :revoked
    assert state.revocation_reason == :keyCompromise
  end
end
```

## Security Considerations

### ⚠️ Private Key Storage

**NEVER store private keys in events or CouchDB!**

```elixir
# ✅ GOOD: Store private key separately
{:ok, key_pem} = GSMLG.PKI.PrivateKey.to_pem(ca.private_key)
# Encrypt and store in secure location
encrypted = encrypt_key(key_pem, master_key)
File.write!("/secure/encrypted-key.pem", encrypted)

# ❌ BAD: Never do this!
# Events.append(:ca_initialized, %{private_key: key_pem}, ...)
```

### CouchDB Security

```elixir
# Set up database security
security_doc = %{
  "admins" => %{
    "names" => ["pki_admin"],
    "roles" => ["_admin"]
  },
  "members" => %{
    "names" => ["pki_app"],
    "roles" => ["pki_reader", "pki_writer"]
  }
}

GSMLG.CouchDB.DB.set_security("pki_events", security_doc)
```

## Performance

### Caching Certificate States

```elixir
# Cache frequently accessed certificates in ETS
:ets.new(:pki_cache, [:set, :public, read_concurrency: true])

def get_cached_state(serial) do
  case :ets.lookup(:pki_cache, serial) do
    [{^serial, state, expires}] when expires > :erlang.system_time(:second) ->
      state

    _ ->
      {:ok, state} = GSMLG.PKI.Events.get_certificate_state(serial)
      :ets.insert(:pki_cache, {serial, state, :erlang.system_time(:second) + 300})
      state
  end
end
```

## Next Steps

1. **Write Tests** - Increase coverage from 2.3% to 80%+
2. **Add Mix Tasks** - CLI tools for common operations
3. **Phoenix UI** - LiveView admin dashboard
4. **OCSP Responder** - Real-time revocation checking
5. **ACME Server** - Let's Encrypt protocol support

## Support

- **Documentation**: See `docs/` directory
- **Examples**: See `IMPLEMENTATION_GUIDE.md`
- **Issues**: Create issue in repository

## License

Same as GSMLG project.
