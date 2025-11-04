# PKI Management Web UI

Complete PKI (Public Key Infrastructure) management interface for GSMLG Admin Web.

## Features Implemented

### Phase 1 - Core PKI Operations ✅
- **CA Management**
  - List all Certificate Authorities with statistics
  - Initialize new CAs with configurable key types (RSA/EC) and sizes
  - View CA details and issued certificates
  - Monitor CA expiration dates

- **Certificate Management**
  - List and filter certificates by status and CA
  - Issue new certificates from CSRs
  - View detailed certificate information
  - Revoke certificates with reasons
  - Download certificates (PEM/DER formats)
  - Track certificate expiration

### Phase 2 - Workflow & CRL ✅
- **CSR Workflow**
  - Upload CSRs for approval
  - Approve/reject pending CSR requests
  - Track CSR request status
  - Automatic certificate issuance on approval

- **CRL Management**
  - Generate Certificate Revocation Lists per CA
  - View current CRL
  - Download CRL (PEM/DER formats)

### Phase 3 - Advanced Features ✅
- **Advanced Search**
  - Search by subject, SAN, serial number, or fingerprint
  - Full-text search across certificates

- **Analytics Dashboard**
  - System-wide PKI statistics
  - Per-CA certificate counts
  - Expiration tracking (7/30/90 day windows)
  - Certificate status distribution

## Installation & Setup

### 1. Run Database Migration

```bash
cd apps/gsmlg
mix ecto.migrate
```

This creates the `pki_csr_requests` table for CSR workflow management.

### 2. Configure Private Key Storage

⚠️ **CRITICAL SECURITY NOTICE** ⚠️

The included `PKIKeyStore` is a **stub implementation** for development only.
**DO NOT use in production without implementing secure key storage!**

Edit `apps/gsmlg_admin_web/lib/gsmlg/admin_web/contexts/pki_key_store.ex` and implement one of:

#### Option A: Hardware Security Module (HSM)
```elixir
config :gsmlg_admin_web, GSMLG.AdminWeb.PKIKeyStore,
  backend: :hsm,
  hsm: [
    library: "/usr/lib/softhsm/libsofthsm2.so",
    slot: 0,
    pin: System.get_env("HSM_PIN")
  ]
```

#### Option B: HashiCorp Vault
```elixir
config :gsmlg_admin_web, GSMLG.AdminWeb.PKIKeyStore,
  backend: :vault,
  vault: [
    address: "https://vault.example.com",
    token: System.get_env("VAULT_TOKEN"),
    path: "transit/keys/pki-ca"
  ]
```

#### Option C: AWS KMS
```elixir
config :gsmlg_admin_web, GSMLG.AdminWeb.PKIKeyStore,
  backend: :kms,
  kms: [
    region: "us-east-1",
    key_id: System.get_env("AWS_KMS_KEY_ID")
  ]
```

#### Option D: Encrypted Filesystem
```elixir
config :gsmlg_admin_web, GSMLG.AdminWeb.PKIKeyStore,
  backend: :encrypted_file,
  encrypted_file: [
    path: "/secure/keys",
    master_key: System.get_env("PKI_MASTER_KEY")
  ]
```

### 3. Start the Application

```bash
mix phx.server
```

Navigate to `http://localhost:4111/pki/ca` (or your admin port).

## Usage Guide

### Initializing Your First CA

1. Navigate to `/pki/ca`
2. Click "Initialize New CA"
3. Fill in the form:
   - **Subject DN**: `/C=US/O=Your Org/CN=Root CA`
   - **Key Type**: RSA or EC
   - **Key Size**: 4096 bits (recommended for RSA)
   - **Validity**: 7300 days (20 years) for root CAs
4. Click "Initialize CA"

The CA certificate and private key will be generated. The private key is stored securely (see configuration above).

### Issuing Certificates

#### Method 1: Direct Issue from CSR

1. Navigate to `/pki/certificates`
2. Click "Issue Certificate"
3. Select a CA
4. Paste the PEM-encoded CSR
5. Select template (server, client, code signing, email)
6. Set validity period
7. Click "Issue Certificate"

#### Method 2: CSR Approval Workflow

1. Navigate to `/pki/csr`
2. Click "Upload CSR"
3. Fill in CSR details
4. Submit for approval
5. Approver navigates to `/pki/csr`
6. Reviews pending CSRs
7. Clicks "Approve" or "Reject"

### Revoking Certificates

1. Navigate to certificate details: `/pki/certificates/{serial}`
2. Click "Revoke Certificate"
3. Select revocation reason
4. Add optional notes
5. Confirm revocation

**Note**: Revocation is permanent and cannot be undone!

### Generating CRLs

1. Navigate to CA details: `/pki/ca/{ca_id}`
2. Click "Generate CRL"
3. Or visit `/pki/crl/{ca_id}` directly
4. Download in PEM or DER format

### Searching Certificates

1. Navigate to `/pki/search`
2. Enter search query
3. Select search type:
   - **Subject**: Search in certificate subject field
   - **SAN**: Search in Subject Alternative Names
   - **Serial**: Exact serial number match
   - **Fingerprint**: Certificate fingerprint
4. Click "Search"

### Viewing Analytics

Navigate to `/pki/analytics` to see:
- Total CA count
- Active/Revoked/Expired certificate counts
- Per-CA statistics
- Expiration warnings (7/30/90 day windows)

## Architecture

### Directory Structure

```
apps/gsmlg_admin_web/
├── lib/gsmlg/admin_web/
│   ├── contexts/
│   │   ├── pki_context.ex          # Business logic layer
│   │   └── pki_key_store.ex        # Private key storage (STUB)
│   └── live/pki_live/
│       ├── ca_live/                 # CA management
│       │   ├── index.ex
│       │   ├── index.html.heex
│       │   ├── show.ex
│       │   └── show.html.heex
│       ├── certificate_live/        # Certificate management
│       │   ├── index.ex
│       │   ├── index.html.heex
│       │   ├── show.ex
│       │   └── show.html.heex
│       ├── csr_live/                # CSR workflow
│       │   ├── index.ex
│       │   └── index.html.heex
│       ├── crl_live/                # CRL management
│       │   ├── index.ex
│       │   └── index.html.heex
│       ├── search_live/             # Certificate search
│       │   ├── index.ex
│       │   └── index.html.heex
│       ├── analytics_live/          # Analytics dashboard
│       │   ├── index.ex
│       │   └── index.html.heex
│       └── components/              # Reusable UI components
│           ├── certificate_card.ex
│           ├── certificate_status.ex
│           ├── pem_viewer.ex
│           └── validity_indicator.ex

apps/gsmlg/
└── lib/gsmlg/schema/
    └── csr_request.ex               # CSR request schema
```

### Key Modules

- **PKIContext**: Business logic wrapper around `gsmlg_pki` library
- **PKIKeyStore**: Private key storage abstraction (requires production implementation)
- **LiveView Modules**: UI controllers for each feature
- **Components**: Reusable DaisyUI-based UI elements

### Data Flow

1. User interacts with LiveView UI
2. LiveView calls `PKIContext` functions
3. `PKIContext` calls `gsmlg_pki` library (event-sourced PKI operations)
4. Events are persisted to PostgreSQL via `GSMLG.PKI.Events`
5. Private keys stored/loaded via `PKIKeyStore`
6. UI updates in real-time via LiveView

### Security Considerations

#### Private Key Security
- Private keys are **NEVER** stored in the event store
- Current implementation stores keys in `/tmp` - **NOT SECURE**
- **MUST** implement production key storage before deployment
- Options: HSM, Vault, KMS, or encrypted filesystem

#### Access Control
- All routes require authentication (`:ensure_authed_access` pipeline)
- Actor tracking: Every PKI operation records the user's email
- Audit trail: All operations are logged as immutable events

#### Certificate Validation
- CSRs are validated before acceptance
- Subject information is extracted and verified
- Revocation requires explicit confirmation

## API Reference

### PKIContext Functions

```elixir
# CA Management
{:ok, cas} = PKIContext.list_cas()
{:ok, ca} = PKIContext.get_ca(ca_id)
{:ok, ca} = PKIContext.initialize_ca(subject, opts)
{:ok, stats} = PKIContext.get_ca_stats(ca_id)

# Certificate Management
{:ok, certs} = PKIContext.list_certificates(opts)
{:ok, cert} = PKIContext.get_certificate(serial)
{:ok, cert} = PKIContext.issue_certificate(ca_id, csr_pem, opts)
:ok = PKIContext.revoke_certificate(ca_id, serial, opts)
{:ok, expiring} = PKIContext.get_expiring_certificates(ca_id, days)

# CSR Workflow
{:ok, csr_request} = PKIContext.create_csr_request(attrs, user_email)
{:ok, requests} = PKIContext.list_csr_requests(opts)
{:ok, cert} = PKIContext.approve_csr_request(id, actor: user_email)
{:ok, _} = PKIContext.reject_csr_request(id, notes)

# CRL Management
{:ok, crl} = PKIContext.generate_crl(ca_id, opts)
{:ok, crl} = PKIContext.get_latest_crl(ca_id)

# Search & Analytics
{:ok, results} = PKIContext.search_certificates(query, type: :subject)
{:ok, analytics} = PKIContext.get_analytics()
{:ok, expiry_stats} = PKIContext.get_expiry_stats()
```

## Testing

### Manual Testing

1. **Initialize CA**: Create a test CA
2. **Generate CSR**: Use OpenSSL to create test CSRs
   ```bash
   openssl req -new -newkey rsa:2048 -nodes -keyout test.key -out test.csr
   ```
3. **Issue Certificate**: Upload CSR and issue
4. **Revoke**: Test revocation workflow
5. **Generate CRL**: Verify revoked cert appears in CRL

### Automated Testing

Run tests:
```bash
cd apps/gsmlg_admin_web
mix test
```

## Troubleshooting

### Issue: "CA not found"
- Ensure CA was successfully initialized
- Check `gsmlg_pki` event store (PostgreSQL `pki_events` table)
- Verify CA ID is correct

### Issue: "Private key not available"
- Check `PKIKeyStore` configuration
- Verify key was stored during CA initialization
- Check file permissions (if using file storage)

### Issue: "Failed to issue certificate"
- Validate CSR format (must be PEM-encoded)
- Ensure CA has a valid private key
- Check CA expiration date

### Issue: "Database migration failed"
- Ensure MariaDB is running
- Check database configuration in `config/dev.exs`
- Run `mix ecto.create` if database doesn't exist

## Production Deployment Checklist

- [ ] Implement production-grade private key storage
- [ ] Configure HSM/Vault/KMS integration
- [ ] Set up automated CRL generation
- [ ] Configure OCSP responder (future feature)
- [ ] Implement role-based access control
- [ ] Set up monitoring and alerting for:
  - Expiring CAs
  - Expiring certificates
  - Failed certificate operations
- [ ] Configure backup procedures for:
  - Private keys (if not in HSM)
  - Event store (PostgreSQL `pki_events` table)
  - CSR request database (PostgreSQL `pki_csr_requests` table)
- [ ] Review and harden security settings
- [ ] Perform security audit
- [ ] Test disaster recovery procedures

## Future Enhancements

### Planned Features
- OCSP responder management
- External CA integration (Let's Encrypt, etc.)
- Certificate chain visualization
- Automated certificate renewal
- Email notifications for expiring certificates
- Certificate templates management
- Batch certificate operations
- REST API for programmatic access

### Contributing

When adding new features:
1. Follow existing LiveView patterns
2. Use `PKIContext` for business logic
3. Leverage `gsmlg_pki` library for PKI operations
4. Add telemetry and logging
5. Include actor tracking
6. Write tests
7. Update this documentation

## Support

For issues or questions:
- Check the `gsmlg_pki` library documentation
- Review GSMLG.Telemetry logs
- Query PostgreSQL `pki_events` table for event debugging

## License

This PKI Management interface is part of the GSMLG Umbrella project.
