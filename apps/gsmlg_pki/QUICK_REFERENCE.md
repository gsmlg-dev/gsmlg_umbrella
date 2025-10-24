# GSMLG.PKI - Quick Reference Guide

## Module Overview

### Core Modules
| Module | Purpose | Key Functions |
|--------|---------|----------------|
| `GSMLG.PKI` | Main entry point | `from_pem/2` - Parse PEM data |
| `GSMLG.PKI.Certificate` | Certificate operations | `self_signed/3`, `new/5`, `from_pem/2`, `to_pem/1` |
| `GSMLG.PKI.PrivateKey` | RSA/EC private keys | `new_rsa/2`, `new_ec/1`, `to_pem/2`, `from_pem/2` |
| `GSMLG.PKI.PublicKey` | Public key operations | `derive/1`, `wrap/2`, `unwrap/1`, `to_pem/2` |
| `GSMLG.PKI.CSR` | Certificate signing requests | `new/3`, `valid?/1`, `public_key/1`, `subject/1` |
| `GSMLG.PKI.CRL` | Certificate revocation lists | `new/4`, `valid?/2`, `list/1`, `issuer/1` |
| `GSMLG.PKI.RDNSequence` | Subject/issuer names | `new/1` - Parse DN strings |
| `GSMLG.PKI.Certificate.Extension` | X.509 extensions | `subject_alt_name/1`, `basic_constraints/2`, `key_usage/1` |
| `GSMLG.PKI.CRL.Entry` | CRL entries | `new/3` - Create revoked entry |
| `GSMLG.PKI.CRL.Extension` | CRL extensions | `crl_number/1`, `crl_reason/1` |

## Common Tasks

### Generate RSA Key Pair
```elixir
private_key = GSMLG.PKI.PrivateKey.new_rsa(2048)
public_key = GSMLG.PKI.PublicKey.derive(private_key)
```

### Generate EC Key Pair
```elixir
private_key = GSMLG.PKI.PrivateKey.new_ec(:secp256r1)
public_key = GSMLG.PKI.PublicKey.derive(private_key)
```

### Create Self-Signed Certificate
```elixir
cert = GSMLG.PKI.Certificate.self_signed(
  private_key,
  "/C=US/ST=CA/O=MyOrg/CN=example.com",
  template: :server,
  extensions: [
    subject_alt_name: GSMLG.PKI.Certificate.Extension.subject_alt_name(
      ["example.com", "www.example.com"]
    )
  ]
)
```

### Create Root CA Certificate
```elixir
ca_cert = GSMLG.PKI.Certificate.self_signed(
  ca_private_key,
  "/C=US/ST=CA/O=MyOrg/CN=Root CA",
  template: :root_ca
)
```

### Issue Certificate from CSR
```elixir
csr = GSMLG.PKI.CSR.new(
  client_private_key,
  "/C=US/ST=CA/O=MyOrg/CN=client.example.com",
  extension_request: [
    GSMLG.PKI.Certificate.Extension.subject_alt_name(["client.example.com"])
  ]
)

cert = GSMLG.PKI.CSR.public_key(csr)
  |> GSMLG.PKI.Certificate.new(
    GSMLG.PKI.CSR.subject(csr),
    ca_cert,
    ca_key,
    template: :server
  )
```

### Create CRL
```elixir
crl = GSMLG.PKI.CRL.new(
  [
    GSMLG.PKI.CRL.Entry.new(
      cert_serial_number,
      DateTime.utc_now(),
      [GSMLG.PKI.CRL.Extension.crl_reason(:superseded)]
    )
  ],
  ca_cert,
  ca_key,
  next_update_in_days: 30
)
```

### Parse Certificate from PEM
```elixir
pem_string = File.read!("cert.pem")
{:ok, cert} = GSMLG.PKI.Certificate.from_pem(pem_string)
# or
cert = GSMLG.PKI.Certificate.from_pem!(pem_string)
```

### Extract Certificate Information
```elixir
version = GSMLG.PKI.Certificate.version(cert)
subject_cn = GSMLG.PKI.Certificate.subject(cert, "CN")
issuer = GSMLG.PKI.Certificate.issuer(cert)
serial = GSMLG.PKI.Certificate.serial(cert)
public_key = GSMLG.PKI.Certificate.public_key(cert)
validity = GSMLG.PKI.Certificate.validity(cert)
extensions = GSMLG.PKI.Certificate.extensions(cert)
```

### Serialize Key/Certificate to PEM
```elixir
# Private key
pem = GSMLG.PKI.PrivateKey.to_pem(private_key)
pem_encrypted = GSMLG.PKI.PrivateKey.to_pem(private_key, password: "secret")

# Public key
pem = GSMLG.PKI.PublicKey.to_pem(public_key)

# Certificate
pem = GSMLG.PKI.Certificate.to_pem(cert)

# CSR
pem = GSMLG.PKI.CSR.to_pem(csr)

# CRL
pem = GSMLG.PKI.CRL.to_pem(crl)
```

### Parse Keys from PEM
```elixir
# Private key
{:ok, key} = GSMLG.PKI.PrivateKey.from_pem(pem)
key = GSMLG.PKI.PrivateKey.from_pem!(pem)
key = GSMLG.PKI.PrivateKey.from_pem!(pem, password: "secret")

# Public key
{:ok, key} = GSMLG.PKI.PublicKey.from_pem(pem)
key = GSMLG.PKI.PublicKey.from_pem!(pem)
```

### Parse Subject/Issuer Names
```elixir
# From string (hierarchical)
subject = GSMLG.PKI.RDNSequence.new("/C=US/ST=CA/CN=example.com")

# From string (comma-separated)
subject = GSMLG.PKI.RDNSequence.new("C=US, ST=CA, CN=example.com")

# From attribute list
subject = GSMLG.PKI.RDNSequence.new([
  countryName: "US",
  stateOrProvinceName: "CA",
  commonName: "example.com"
])

# Extract attributes from certificate
cn = GSMLG.PKI.Certificate.subject(cert, :commonName)
cn = GSMLG.PKI.Certificate.subject(cert, "CN")
```

## Certificate Templates

### Available Templates
- `:root_ca` - Root CA (25yr, basic_constraints: path_len=1)
- `:ca` - Intermediate CA (10yr, basic_constraints: path_len=0)
- `:server` - Server/End-entity (1yr, serverAuth + clientAuth)
- `:ocsp_responder` - OCSP Responder (30d, ocspSigning only)

### Custom Template
```elixir
cert = GSMLG.PKI.Certificate.self_signed(
  key,
  subject,
  template: :server,
  validity: 730,  # 2 years
  hash: :sha512,
  serial: 12345,
  extensions: [
    basic_constraints: false,
    key_usage: [:digitalSignature, :keyEncipherment]
  ]
)
```

## Certificate Extensions

### Common Extensions
```elixir
# Subject Alternative Names (for hostnames)
GSMLG.PKI.Certificate.Extension.subject_alt_name(
  ["example.com", "www.example.com", "api.example.com"]
)

# Key Usage (what the key can be used for)
GSMLG.PKI.Certificate.Extension.key_usage(
  [:digitalSignature, :keyEncipherment]
)

# Extended Key Usage (additional constraints)
GSMLG.PKI.Certificate.Extension.ext_key_usage(
  [:serverAuth, :clientAuth]
)

# Basic Constraints (CA certificate marking)
GSMLG.PKI.Certificate.Extension.basic_constraints(true, 0)  # CA, path_len=0
GSMLG.PKI.Certificate.Extension.basic_constraints(false)    # Not a CA

# Authority Information Access (OCSP, issuer URLs)
GSMLG.PKI.Certificate.Extension.authority_information_access([
  {:ocsp, "http://ocsp.example.com"},
  {:ca_issuers, "http://ca.example.com/ca.pem"}
])

# CRL Distribution Points (where to get CRL)
GSMLG.PKI.Certificate.Extension.crl_distribution_points(
  ["http://crl.example.com/root.crl"]
)

# Subject Key Identifier (auto-calculated)
extensions: [subject_key_identifier: true]

# Authority Key Identifier (auto-calculated)
extensions: [authority_key_identifier: true]
```

## Hash Algorithms

Supported for certificate signing:
- `:sha256` (recommended)
- `:sha224`
- `:sha384`
- `:sha512`
- `:sha` (legacy)
- `:md5` (legacy, RSA only)

## Mix Tasks

### Generate Self-Signed Certificate
```bash
mix gsmlg.pki.gen.selfsigned
mix gsmlg.pki.gen.selfsigned my-app --output priv/cert/my-app
mix gsmlg.pki.gen.selfsigned localhost 127.0.0.1 --name "Development Server"
```

### Generate Root CA
```bash
mix gsmlg.pki.gen.root
```

### Generate Test Suite
```bash
mix gsmlg.pki.gen.suite
```

### Run Test Server
```bash
mix gsmlg.pki.test_server
```

## Type Signatures

### Key Types
```elixir
@type GSMLG.PKI.PrivateKey.t :: :RSAPrivateKey | :ECPrivateKey
@type GSMLG.PKI.PublicKey.t :: :RSAPublicKey | {:ECPoint, params}
```

### Certificate Types
```elixir
@type GSMLG.PKI.Certificate.t :: :OTPCertificate
@type GSMLG.PKI.CSR.t :: :CertificationRequest
@type GSMLG.PKI.CRL.t :: :CertificateList
@type GSMLG.PKI.RDNSequence.t :: :rdnSequence
```

## Error Handling

### Result Tuples
```elixir
# Successful operations return results directly
cert = GSMLG.PKI.Certificate.self_signed(key, subject)

# Parse operations return result tuples
{:ok, cert} = GSMLG.PKI.Certificate.from_pem(pem)
{:error, :not_found} = GSMLG.PKI.Certificate.from_pem(invalid_pem)

# Or use bang versions that raise
cert = GSMLG.PKI.Certificate.from_pem!(pem)  # raises on error
```

### Common Error Reasons
- `:malformed` - Data could not be decoded
- `:not_found` - Expected PEM entry not found

## Best Practices

1. **Key Generation**
   - Use at least 2048-bit RSA or secp256r1 EC
   - Prefer EC keys for better performance

2. **Certificate Validity**
   - Root CA: 10-25 years
   - Intermediate CA: 5-10 years
   - Server/Client: 1-2 years
   - OCSP Responder: 30 days (due to OCSP Nocheck)

3. **Subject Names**
   - Always include C (Country), O (Organization), CN (Common Name)
   - Use FQDN for server certificates
   - Use descriptive organization names

4. **Extensions**
   - Always set Basic Constraints for CA certificates
   - Include SAN for all hostnames
   - Include Key Usage and Extended Key Usage
   - Include CRL Distribution Points
   - Include Authority Information Access (OCSP, Issuers)

5. **Hash Algorithms**
   - Default to SHA256 (good security/performance balance)
   - Use SHA512 for high-security certificates
   - Avoid SHA1, MD5, and SHA (deprecated)

6. **Key Protection**
   - Always protect private keys with passwords
   - Store passwords securely (not in source code)
   - Use secure random for serial numbers

## Known Limitations

1. **No Certificate Chain Validation** - Cannot verify leaf->root path
2. **No Revocation Checking** - Cannot check OCSP or CRL status
3. **No Key Rotation** - Must manually rotate keys
4. **No Persistence** - All operations are in-memory
5. **No HSM Support** - No hardware security module integration
6. **No Post-Quantum Crypto** - Limited to RSA and ECDSA
7. **No ACME Support** - Cannot integrate with Let's Encrypt
8. **No Delta CRLs** - CRL generation only
9. **No Policy Processing** - Cannot enforce certificate policies
10. **No Name Constraints** - Cannot restrict certificate usage by name

## Performance Notes

- Key generation: 100-500ms (depends on key size)
- Certificate signing: 10-50ms
- CSR creation: 10-50ms
- CRL generation: 50-200ms
- PEM/DER encoding/parsing: <1ms

## Related Resources

- [RFC 5280 - X.509 PKI](https://tools.ietf.org/html/rfc5280)
- [Erlang/OTP Public Key Module](https://erlang.org/doc/man/public_key.html)
- [PKCS #10 - CSR Specification](https://tools.ietf.org/html/rfc2986)
- [PKCS #8 - Private Key Syntax](https://tools.ietf.org/html/rfc5208)
