# Event-Sourced PKI Implementation Guide

## Overview

This guide documents the Event-Sourced Phoenix PKI implementation for GSMLG. The system provides a complete Certificate Authority with event sourcing, comprehensive audit trails, and integration with CouchDB and Telemetry.

## Architecture

### Core Components

1. **GSMLG.PKI.Events** - Event sourcing API
2. **GSMLG.PKI.Store.CouchDB** - Event storage adapter
3. **GSMLG.PKI.CA** - High-level CA operations
4. **GSMLG.PKI.Validator** - Chain validation engine
5. **Existing GSMLG.PKI modules** - Low-level crypto operations

### Event Flow

```
CA Operation (issue, revoke, etc.)
    ↓
GSMLG.PKI.CA
    ↓
Generate Certificate/CRL
    ↓
GSMLG.PKI.Events.append()
    ↓
GSMLG.PKI.Store.CouchDB.store_event()
    ↓
CouchDB (immutable event log)
    ↓
GSMLG.Telemetry (audit logging)
```

### State Reconstruction

```
Query Events by Serial
    ↓
GSMLG.PKI.Events.get_certificate_state()
    ↓
Replay Events (reduce)
    ↓
Current Certificate State
```

## Setup and Configuration

### 1. Database Setup

The PKI system requires CouchDB to be running and configured. Add to your config:

```elixir
# config/config.exs
config :gsmlg_couchdb, GSMLG.CouchDB.Connection,
  scheme: :http,
  host: "localhost",
  port: 5984,
  username: "admin",
  password: "admin"

config :gsmlg_pki, GSMLG.PKI.Store.CouchDB,
  database: "pki_events"
```

### 2. Initialize Database

Run this once to create the database and indexes:

```elixir
iex> GSMLG.PKI.Store.CouchDB.setup()
:ok
```

Or create a migration:

```elixir
defmodule GSMLG.Repo.Migrations.SetupPKIEventStore do
  use Ecto.Migration

  def up do
    # This is run from Ecto but calls CouchDB setup
    GSMLG.PKI.Store.CouchDB.setup()
  end

  def down do
    # Optionally drop the database
    GSMLG.CouchDB.DB.delete_db("pki_events")
  end
end
```

## Usage Examples

### Initialize a Root CA

```elixir
# Create a new root CA
{:ok, root_ca} = GSMLG.PKI.CA.initialize(
  "/CN=GSMLG Root CA/O=GSMLG/C=US",
  key_type: :rsa,
  key_size: 4096,
  validity: 7300,  # 20 years
  actor: "admin@gsmlg.net"
)

# Save the private key securely (NOT in events!)
{:ok, pem} = GSMLG.PKI.PrivateKey.to_pem(root_ca.private_key)
File.write!("/secure/path/root-ca-key.pem", pem)

# Save the certificate
{:ok, cert_pem} = GSMLG.PKI.Certificate.to_pem(root_ca.certificate)
File.write!("/path/to/root-ca-cert.pem", cert_pem)
```

### Issue a Server Certificate from CSR

```elixir
# Read CSR from file or request
csr_pem = File.read!("server.csr")

# Issue certificate
{:ok, server_cert} = GSMLG.PKI.CA.issue_certificate(
  root_ca,
  csr_pem,
  template: :server,
  validity: 365,
  extensions: [
    subject_alt_name: ["example.com", "www.example.com", "mail.example.com"]
  ],
  actor: "admin@gsmlg.net"
)

# Export certificate
{:ok, cert_pem} = GSMLG.PKI.Certificate.to_pem(server_cert)
File.write!("server-cert.pem", cert_pem)
```

### Issue a Client Certificate Directly

```elixir
# Generate key pair
client_key = GSMLG.PKI.PrivateKey.new_rsa(2048)
client_public_key = GSMLG.PKI.PublicKey.derive(client_key)

# Issue client certificate
{:ok, client_cert} = GSMLG.PKI.CA.issue_certificate_direct(
  root_ca,
  client_public_key,
  "/CN=john.doe@example.com/O=Example Inc",
  template: :client,
  validity: 730,  # 2 years
  extensions: [
    subject_alt_name: ["email:john.doe@example.com"]
  ],
  actor: "admin@gsmlg.net"
)
```

### Revoke a Certificate

```elixir
# Get certificate serial from certificate
import GSMLG.PKI.ASN1
otp_certificate(tbsCertificate: tbs) = client_cert
otp_tbs_certificate(serialNumber: serial) = tbs

# Revoke the certificate
:ok = GSMLG.PKI.CA.revoke_certificate(
  root_ca,
  serial,
  reason: :keyCompromise,
  actor: "security@gsmlg.net"
)
```

### Generate CRL

```elixir
# Generate CRL with all revoked certificates
{:ok, crl} = GSMLG.PKI.CA.generate_crl(root_ca, validity: 7)

# Export CRL
{:ok, crl_der} = GSMLG.PKI.CRL.to_der(crl)
File.write!("root-ca.crl", crl_der)

# Or PEM format
{:ok, crl_pem} = GSMLG.PKI.CRL.to_pem(crl)
File.write!("root-ca.crl.pem", crl_pem)
```

### Validate Certificate Chain

```elixir
# Validate a certificate
{:ok, :valid} = GSMLG.PKI.Validator.validate_chain(
  server_cert,
  [root_ca.certificate],
  check_revocation: true,
  usage: :serverAuth
)

# Check if specific certificate is revoked
{:ok, :not_revoked} = GSMLG.PKI.Validator.check_revocation(server_cert)

# For revoked certificate
{:ok, {:revoked, :keyCompromise}} = GSMLG.PKI.Validator.check_revocation(revoked_cert)
```

### Query Certificate State

```elixir
# Get current state of a certificate
{:ok, state} = GSMLG.PKI.Events.get_certificate_state(serial)

# State includes:
# %{
#   status: :active | :revoked | :expired,
#   serial: 12345,
#   subject: "/CN=example.com",
#   not_before: ~U[2025-01-01 00:00:00Z],
#   not_after: ~U[2026-01-01 00:00:00Z],
#   certificate_der: <<...>>,
#   revoked_at: nil,  # or DateTime if revoked
#   revocation_reason: nil,  # or atom if revoked
#   events: [...]  # all events for this certificate
# }
```

### Get CA Statistics

```elixir
{:ok, stats} = GSMLG.PKI.CA.get_stats("ca:root")

# Returns:
# %{
#   active_certificates: 42,
#   revoked_certificates: 5,
#   expired_certificates: 3,
#   total_issued: 50
# }
```

### Monitor Expiring Certificates

```elixir
# Get certificates expiring in next 30 days
{:ok, expiring} = GSMLG.PKI.CA.get_expiring_certificates("ca:root", 30)

# Each entry includes:
# %{
#   serial: 12345,
#   subject: "/CN=example.com",
#   not_after: ~U[2025-11-23 00:00:00Z],
#   days_remaining: 25,
#   ...
# }

# Set up renewal workflow
Enum.each(expiring, fn cert ->
  if cert.days_remaining <= 7 do
    send_expiry_notification(cert)
  end
end)
```

### Query Events

```elixir
# Get all events for a CA
{:ok, events} = GSMLG.PKI.Events.query_by_ca("ca:root")

# Get recent events
{:ok, recent} = GSMLG.PKI.Events.query_by_ca("ca:root", limit: 10, descending: true)

# Get all revocations
{:ok, revocations} = GSMLG.PKI.Events.query_by_type(:certificate_revoked)

# Get all events for a specific certificate
{:ok, cert_events} = GSMLG.PKI.Events.query_by_serial(12345)
```

## Integration with Existing GSMLG Apps

### Guardian JWT Integration

Create certificate-based authentication:

```elixir
defmodule GSMLGWeb.PKIAuthPlug do
  @moduledoc """
  Authenticate users via client certificates.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, cert_der} <- extract_peer_cert(conn),
         {:ok, cert} <- GSMLG.PKI.Certificate.from_der(cert_der),
         {:ok, :valid} <- GSMLG.PKI.Validator.validate_chain(cert, get_trust_anchors()),
         {:ok, user} <- find_user_by_certificate(cert) do
      # Sign in via Guardian
      GSMLG.Guardian.Plug.sign_in(conn, user)
    else
      _ ->
        conn
        |> send_resp(401, "Invalid certificate")
        |> halt()
    end
  end

  defp extract_peer_cert(conn) do
    # Extract certificate from SSL context
    # Implementation depends on Phoenix SSL configuration
  end

  defp get_trust_anchors do
    # Load trusted root certificates
    Application.get_env(:gsmlg_pki, :trust_anchors, [])
  end

  defp find_user_by_certificate(cert) do
    # Match certificate to user account
    # Could use subject DN, SAN email, or certificate serial
  end
end
```

### Phoenix SSL Configuration

```elixir
# config/runtime.exs
config :gsmlg_web, GSMLGWeb.Endpoint,
  https: [
    port: 4443,
    cipher_suite: :strong,
    certfile: "/path/to/server-cert.pem",
    keyfile: "/path/to/server-key.pem",
    cacertfile: "/path/to/root-ca-cert.pem",
    verify: :verify_peer,
    fail_if_no_peer_cert: false  # Set to true for mandatory client certs
  ]
```

### Telemetry Events

The PKI system emits comprehensive telemetry events:

```elixir
# Attach telemetry handlers
:telemetry.attach_many(
  "pki-telemetry",
  [
    [:gsmlg, :pki, :ca, :initialize],
    [:gsmlg, :pki, :certificate, :issue],
    [:gsmlg, :pki, :certificate, :revoke],
    [:gsmlg, :pki, :crl, :generate],
    [:gsmlg, :pki, :validation, :chain],
    [:gsmlg, :pki, :event, :appended]
  ],
  &handle_pki_event/4,
  nil
)

defp handle_pki_event(event_name, measurements, metadata, _config) do
  # Log to CloudWatch, metrics system, etc.
  GSMLG.Telemetry.log(:info, "PKI event: #{inspect(event_name)}",
    metadata: Map.merge(measurements, metadata)
  )
end
```

## Mix Tasks

### Create Mix Task for CA Initialization

```elixir
# lib/mix/tasks/gsmlg/pki/ca/init.ex
defmodule Mix.Tasks.Gsmlg.Pki.Ca.Init do
  use Mix.Task

  @shortdoc "Initialize a new Certificate Authority"

  @moduledoc """
  Initialize a new Certificate Authority.

  Usage:
      mix gsmlg.pki.ca.init --subject "/CN=My CA" --key-type rsa --key-size 4096

  Options:
      --subject       - CA subject DN (required)
      --key-type      - Key type: rsa or ec (default: rsa)
      --key-size      - RSA key size (default: 4096)
      --curve         - EC curve (default: secp384r1)
      --validity      - Validity in days (default: 7300)
      --output        - Output directory for CA files (default: ./ca)
  """

  def run(args) do
    Mix.Task.run("app.start")

    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          subject: :string,
          key_type: :string,
          key_size: :integer,
          curve: :string,
          validity: :integer,
          output: :string
        ]
      )

    subject = Keyword.fetch!(opts, :subject)
    key_type = String.to_existing_atom(Keyword.get(opts, :key_type, "rsa"))
    key_size = Keyword.get(opts, :key_size, 4096)
    curve = String.to_existing_atom(Keyword.get(opts, :curve, "secp384r1"))
    validity = Keyword.get(opts, :validity, 7300)
    output_dir = Keyword.get(opts, :output, "./ca")

    Mix.shell().info("Initializing CA: #{subject}")

    {:ok, ca} =
      GSMLG.PKI.CA.initialize(subject,
        key_type: key_type,
        key_size: key_size,
        curve: curve,
        validity: validity,
        actor: "mix-task"
      )

    File.mkdir_p!(output_dir)

    # Save certificate
    {:ok, cert_pem} = GSMLG.PKI.Certificate.to_pem(ca.certificate)
    cert_path = Path.join(output_dir, "ca-cert.pem")
    File.write!(cert_path, cert_pem)

    # Save private key
    {:ok, key_pem} = GSMLG.PKI.PrivateKey.to_pem(ca.private_key)
    key_path = Path.join(output_dir, "ca-key.pem")
    File.write!(key_path, key_pem)
    File.chmod!(key_path, 0o600)  # Secure private key

    Mix.shell().info("CA initialized successfully!")
    Mix.shell().info("Certificate: #{cert_path}")
    Mix.shell().info("Private Key: #{key_path} (keep secure!)")
    Mix.shell().info("CA ID: #{ca.id}")
  end
end
```

## Event Sourcing Benefits

### Perfect Audit Trail

Every operation is logged as an immutable event:

```elixir
# Query complete audit trail
{:ok, events} = GSMLG.PKI.Events.query_by_ca("ca:root")

# Each event includes:
# - Timestamp (when)
# - Event type (what)
# - Actor (who)
# - Metadata (details)
# - Correlation ID (request tracking)

# Example: trace certificate lifecycle
{:ok, cert_events} = GSMLG.PKI.Events.query_by_serial(12345)

# Events might be:
# 1. certificate_issued (2025-01-01)
# 2. certificate_validated (2025-01-15)
# 3. certificate_validated (2025-02-01)
# 4. certificate_revoked (2025-03-01)
```

### Time Travel Debugging

```elixir
# "What was the state of this certificate on February 1st?"
past_time = ~U[2025-02-01 00:00:00Z]
{:ok, state} = GSMLG.PKI.Events.get_certificate_state(12345)

# Replay events up to that point
historical_state =
  state.events
  |> Enum.filter(&(DateTime.compare(&1.timestamp, past_time) != :gt))
  |> replay_events()

# historical_state.status => :active (before revocation)
```

### CRL Generation Without Storage

```elixir
# CRLs are generated on-demand from events, no separate storage needed
{:ok, revocations} = GSMLG.PKI.Events.get_revocations("ca:root")

# Generate CRL
{:ok, crl} = GSMLG.PKI.CRL.new(
  revocations,
  root_ca.certificate,
  root_ca.private_key
)

# Delta CRL (revocations since last CRL)
last_crl_time = get_last_crl_timestamp("ca:root")
{:ok, recent_revocations} = GSMLG.PKI.Events.get_revocations("ca:root", since: last_crl_time)
{:ok, delta_crl} = generate_delta_crl(recent_revocations)
```

### Horizontal Scalability

```elixir
# CouchDB replication provides HA and scalability
config :gsmlg_couchdb,
  replicate_to: [
    "http://couch-replica-1:5984/pki_events",
    "http://couch-replica-2:5984/pki_events"
  ]

# Read from any replica
# Events are immutable, no consistency issues
```

## Security Considerations

### Private Key Storage

**IMPORTANT**: Private keys are NEVER stored in events!

```elixir
# After CA initialization, store private key securely
{:ok, key_pem} = GSMLG.PKI.PrivateKey.to_pem(ca.private_key)

# Option 1: Encrypted file
encrypted = :crypto.block_encrypt(:aes_gcm, key, iv, key_pem)
File.write!("/secure/ca-key.enc", encrypted)

# Option 2: HSM (future enhancement)
# Store in Hardware Security Module

# Option 3: Key management service
# AWS KMS, HashiCorp Vault, etc.
```

### Event Database Security

```elixir
# CouchDB security document
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

### Validation Functions

```elixir
# CouchDB validation function to prevent event modification
validation_fun = """
function(newDoc, oldDoc, userCtx) {
  if (oldDoc && newDoc._id === oldDoc._id) {
    throw({forbidden: 'Events are immutable'});
  }
  if (newDoc.type !== 'pki_event') {
    throw({forbidden: 'Only PKI events allowed'});
  }
  if (!newDoc.timestamp || !newDoc.ca_id) {
    throw({forbidden: 'Missing required fields'});
  }
}
"""
```

## Testing

### Unit Tests

```elixir
defmodule GSMLG.PKI.CATest do
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

  test "issue certificate", %{ca: ca} do
    key = GSMLG.PKI.PrivateKey.new_rsa(2048)
    public_key = GSMLG.PKI.PublicKey.derive(key)

    {:ok, cert} = GSMLG.PKI.CA.issue_certificate_direct(
      ca,
      public_key,
      "/CN=test.example.com",
      template: :server,
      validity: 365
    )

    assert cert != nil

    # Verify event was logged
    import GSMLG.PKI.ASN1
    otp_certificate(tbsCertificate: tbs) = cert
    otp_tbs_certificate(serialNumber: serial) = tbs

    {:ok, state} = GSMLG.PKI.Events.get_certificate_state(serial)
    assert state.status == :active
  end

  test "revoke certificate", %{ca: ca} do
    # Issue certificate
    key = GSMLG.PKI.PrivateKey.new_rsa(2048)
    public_key = GSMLG.PKI.PublicKey.derive(key)
    {:ok, cert} = GSMLG.PKI.CA.issue_certificate_direct(ca, public_key, "/CN=test")

    # Get serial
    import GSMLG.PKI.ASN1
    otp_certificate(tbsCertificate: tbs) = cert
    otp_tbs_certificate(serialNumber: serial) = tbs

    # Revoke
    :ok = GSMLG.PKI.CA.revoke_certificate(ca, serial, reason: :keyCompromise)

    # Verify revocation
    {:ok, state} = GSMLG.PKI.Events.get_certificate_state(serial)
    assert state.status == :revoked
    assert state.revocation_reason == :keyCompromise
  end

  test "generate CRL", %{ca: ca} do
    {:ok, crl} = GSMLG.PKI.CA.generate_crl(ca)
    assert crl != nil

    # Verify CRL is valid
    {:ok, crl_der} = GSMLG.PKI.CRL.to_der(crl)
    assert byte_size(crl_der) > 0
  end
end
```

## Performance Considerations

### Event Caching

```elixir
# Cache frequently accessed certificate states in ETS
defmodule GSMLG.PKI.StateCache do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    table = :ets.new(:pki_state_cache, [:set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  def get_state(serial) do
    case :ets.lookup(:pki_state_cache, serial) do
      [{^serial, state, expires_at}] ->
        if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
          {:ok, state}
        else
          fetch_and_cache(serial)
        end

      [] ->
        fetch_and_cache(serial)
    end
  end

  defp fetch_and_cache(serial) do
    {:ok, state} = GSMLG.PKI.Events.get_certificate_state(serial)
    expires_at = DateTime.add(DateTime.utc_now(), 300, :second)  # 5 min TTL
    :ets.insert(:pki_state_cache, {serial, state, expires_at})
    {:ok, state}
  end
end
```

### Batch Operations

```elixir
# Issue multiple certificates in batch
certificates =
  Enum.map(csrs, fn csr ->
    GSMLG.PKI.CA.issue_certificate(ca, csr)
  end)

# Events are appended individually but can be queried efficiently
```

## Next Steps

1. **Add Phoenix UI** - Create LiveView admin interface
2. **OCSP Responder** - Real-time revocation checking
3. **ACME Server** - Automated certificate enrollment (Let's Encrypt protocol)
4. **HSM Integration** - Hardware key storage
5. **Certificate Templates** - Configurable issuance policies
6. **Automated Renewal** - Background job for expiring certificates
7. **Multi-Tenant Support** - Isolate CAs per tenant
8. **Metrics Dashboard** - Real-time CA metrics via LiveView

## Conclusion

The Event-Sourced PKI system provides:

- ✅ Complete Certificate Authority functionality
- ✅ Perfect audit trail via event sourcing
- ✅ CouchDB persistence with horizontal scalability
- ✅ Chain validation with revocation checking
- ✅ Comprehensive telemetry integration
- ✅ Zero external dependencies (pure OTP + CouchDB)
- ✅ Production-ready error handling
- ✅ Extensible architecture for future enhancements

This implementation achieves the goal of making gsmlg_pki a complete, full-featured PKI system for the GSMLG application while leveraging the unique strengths of the Elixir/OTP ecosystem and the umbrella architecture.
