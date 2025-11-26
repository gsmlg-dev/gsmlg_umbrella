# User Guide: Enhanced PKI CA Creation

**Feature**: Enhanced PKI CA Creation Form
**Version**: 1.0
**Last Updated**: 2025-11-25

---

## Overview

The Enhanced PKI CA Creation Form provides a comprehensive interface for initializing Certificate Authorities (CAs) with fine-grained control over cryptographic parameters, subject information, and security settings.

## Accessing the CA Creation Form

1. Log in to the GSMLG Admin interface
2. Navigate to **PKI** → **Certificate Authorities** in the left menu
3. Click **Initialize New CA** button

## Form Sections

### 1. Subject Information

The Distinguished Name (DN) identifies your CA in the X.509 certificate chain.

| Field | Required | Description | Example |
|-------|----------|-------------|---------|
| **Common Name (CN)** | ✅ Yes | Primary name for the CA. Appears in certificate chains and trust stores. | `Example Root CA` |
| **Organization (O)** | ❌ No | Your company or organization name | `Example Corp` |
| **Organizational Unit (OU)** | ❌ No | Department or division | `IT Department` |
| **Country (C)** | ❌ No | Two-letter ISO 3166-1 country code (uppercase) | `US`, `GB`, `CN` |
| **State/Province (ST)** | ❌ No | State or province name | `California` |
| **Locality (L)** | ❌ No | City or locality name | `San Francisco` |

**Best Practices**:
- Use unique Common Names to avoid collisions
- Include Organization for production CAs
- Follow your organization's naming conventions

**Example DN**: `/CN=Example Root CA/O=Example Corp/OU=IT/C=US/ST=California/L=San Francisco`

---

### 2. Key Configuration

Choose the cryptographic algorithm for your CA's private/public key pair.

#### Key Type Selection

| Algorithm | Description | Security Level | Performance | Best For |
|-----------|-------------|----------------|-------------|----------|
| **RSA** | Traditional algorithm, maximum compatibility | High | Slower | Legacy systems, broad compatibility |
| **ECDSA** | Modern elliptic curve cryptography | Very High | Fast | Modern systems, smaller certificates |
| **Ed25519** | State-of-the-art Edwards curve | Maximum | Fastest | New deployments, maximum security |

#### Key Size Options

**RSA** (select one):
- `2048` bits - Minimum recommended (fast, but lower security)
- `3072` bits - Medium security (good balance)
- `4096` bits - **Recommended** (industry standard)
- `8192` bits - Maximum security (slow generation, large certificates)

**ECDSA** (select one):
- `256` bits (P-256 / secp256r1) - Standard security
- `384` bits (P-384 / secp384r1) - **Recommended** (high security)
- `521` bits (P-521 / secp521r1) - Maximum security

**Ed25519**:
- Fixed `256` bits (no selection needed) - Automatically provides maximum security

**Recommendations**:
- **Production Root CAs**: RSA 4096 or ECDSA P-384
- **Internal/Development CAs**: RSA 2048 or ECDSA P-256
- **New Systems Only**: Ed25519 (highest security, but limited compatibility)

---

### 3. Validity Period

Specify the exact date/time range when your CA certificate will be valid.

**Fields**:
- **Valid From**: Start date/time (default: current time)
- **Valid Until**: End date/time (default: 10 years from now)

**Duration Display**: Real-time calculation shows validity period in years, months, and days.

**Best Practices**:
- **Root CAs**: 10-20 years (default 10 years recommended)
- **Intermediate CAs**: 5-10 years
- **Never exceed 20 years** (system will warn)

**Why 10 Years?**
- Industry best practice balances security and operational stability
- Allows time for certificate issuance before expiration
- Aligns with compliance requirements (PCI DSS, CA/Browser Forum)

**Warning**: The system will display an alert if you select a validity period exceeding 20 years, as this violates industry standards.

---

### 4. Private Key Security

Optionally encrypt your CA's private key with a password for additional security.

#### Encryption Checkbox

- ✅ **Checked**: Private key will be encrypted with PKCS#8 password-based encryption
- ⬜ **Unchecked**: Private key stored unencrypted (default)

#### Password Requirements

**When encryption is enabled**, you must provide:
- **Minimum length**: 12 characters
- **Complexity**: Must contain:
  - At least one **uppercase** letter (A-Z)
  - At least one **lowercase** letter (a-z)
  - At least one **digit** (0-9)
- **Confirmation**: Re-enter password to prevent typos

**Example valid passwords**:
- `MySecureCA2025!`
- `RootCertAuth#123`
- `P@ssw0rdForCA42`

⚠️ **CRITICAL**: The password is **NOT stored anywhere**. You must remember it! If lost, the encrypted private key cannot be recovered.

#### When to Encrypt?

| Scenario | Recommendation |
|----------|----------------|
| Production root CA with offline storage | ✅ **Encrypt** - Maximum security |
| Development/test CA | ⬜ No encryption - Easier management |
| CA stored on encrypted filesystem | ⬜ Optional - Filesystem encryption may suffice |
| Compliance requirements (PCI DSS, HIPAA) | ✅ **Encrypt** - Often required |
| CA used by automated systems | ⬜ No encryption - Avoids password management complexity |

---

## Step-by-Step: Creating Your First CA

### Example 1: Development Root CA (Quick Setup)

**Goal**: Simple CA for local development

1. **Subject Information**:
   - Common Name: `Dev Root CA`
   - Organization: `Development`
   - Country: `US`

2. **Key Configuration**:
   - Key Type: `RSA`
   - Key Size: `2048` bits

3. **Validity Period**:
   - Accept defaults (10 years)

4. **Private Key Security**:
   - Leave encryption unchecked

5. Click **Initialize CA**

**Result**: CA created in ~1 second, ready for issuing development certificates.

---

### Example 2: Production Root CA (Secure Setup)

**Goal**: Production CA with maximum security

1. **Subject Information**:
   - Common Name: `Example Corp Root CA 2025`
   - Organization: `Example Corp`
   - Organizational Unit: `PKI Operations`
   - Country: `US`
   - State: `California`
   - Locality: `San Francisco`

2. **Key Configuration**:
   - Key Type: `ECDSA`
   - Key Size: `384` bits (P-384)

3. **Validity Period**:
   - Valid From: `2025-01-01 00:00:00`
   - Valid Until: `2035-01-01 00:00:00` (10 years)

4. **Private Key Security**:
   - ✅ Enable encryption
   - Password: `MySecureCA2025!` (remember this!)
   - Confirm Password: `MySecureCA2025!`

5. Click **Initialize CA**

**Result**: CA created in ~2-3 seconds with encrypted private key. Store password in secure password manager!

---

### Example 3: Maximum Security CA (Ed25519)

**Goal**: Cutting-edge security for new deployments

1. **Subject Information**:
   - Common Name: `Ed25519 Root CA 2025`
   - Organization: `Example Corp`
   - Country: `US`

2. **Key Configuration**:
   - Key Type: `Ed25519`
   - *(Key size fixed at 256 bits)*

3. **Validity Period**:
   - Accept defaults (10 years)

4. **Private Key Security**:
   - ✅ Enable encryption
   - Password: `Ed25519Secure#2025`
   - Confirm Password: `Ed25519Secure#2025`

5. Click **Initialize CA**

**Result**: CA created in < 1 second (Ed25519 is fastest!). Highest security available.

---

## Loading Indicator

During CA creation (which can take 1-5 seconds depending on key size), the **Initialize CA** button will:
- Change to "Generating Keys..."
- Display a loading spinner
- Become disabled to prevent duplicate submissions

**Typical Generation Times**:
- Ed25519: < 1 second
- RSA 2048: ~1 second
- ECDSA P-384: ~1-2 seconds
- RSA 4096: ~2-3 seconds
- RSA 8192: ~5-10 seconds

---

## Success and Error Messages

### Success Message Format

```
CA 'Example Root CA' initialized successfully with RSA-4096 key (encrypted). Serial: abc123def456
```

Includes:
- CA Common Name
- Key algorithm and size
- Encryption status
- Certificate serial number

### Common Errors

| Error Message | Cause | Solution |
|---------------|-------|----------|
| `Invalid key configuration: ecdsa does not support 4096-bit keys` | Selected incompatible key size for algorithm | Choose valid size from dropdown |
| `A CA with Common Name 'Example Root CA' already exists` | Duplicate Common Name | Use a unique CN (e.g., add year or version) |
| `Password must be at least 12 characters` | Password too short | Use 12+ character password |
| `Password does not match` | Password confirmation mismatch | Re-enter matching passwords |
| `Country code must be exactly 2 uppercase letters` | Invalid country code format | Use 2-letter code: `US`, `GB`, `CN` |
| `Key generation failed` | System resource issue | Try smaller key size or retry |
| `Unable to save CA to database` | Database connection issue | Contact system administrator |

---

## Help Tooltips

Hover over the **ⓘ** icon next to field labels for quick help:

- **Common Name**: "The primary name for this CA. Appears in certificate chains and trust stores."
- **Key Type**: "RSA: Traditional, widely supported. ECDSA: Modern, smaller keys. Ed25519: Fastest, most secure."
- **Validity Period**: "CA certificate will be valid from start date to end date. Default is 10 years. Industry best practice: max 20 years."

---

## After CA Creation

Once your CA is successfully created:

1. **CA appears in list** with status badge:
   - 🟢 **Key Available**: Private key is accessible
   - 🔴 **No Key**: Private key missing (error state)

2. **CA Details** displayed:
   - Subject DN
   - Key Type and Size
   - Serial Number
   - Validity Period
   - Statistics (active/revoked/expired certificates)

3. **Next Steps**:
   - Click **View Details** to see full CA information
   - Use CA to issue certificates (Certificate Signing Requests)
   - Export CA certificate for distribution to trust stores
   - Set up automated certificate issuance workflows

---

## Security Recommendations

### Password Management

✅ **DO**:
- Use a password manager (1Password, LastPass, Bitwarden)
- Store encrypted private keys offline in HSM/smart card
- Document password recovery procedures
- Use different passwords for different CAs
- Include password in disaster recovery plan

❌ **DON'T**:
- Write passwords on paper/sticky notes
- Store passwords in plain text files
- Reuse passwords across CAs
- Share passwords via email/chat
- Assume you'll remember complex passwords

### CA Key Protection

**Critical**: The private key is the most sensitive asset in your PKI infrastructure!

1. **Backup**: Immediately back up CA certificate + encrypted private key to secure offline storage
2. **Access Control**: Limit CA creation to authorized PKI administrators only
3. **Audit Logging**: All CA operations are logged with user ID, timestamp, and details
4. **Key Rotation**: Plan for CA renewal before expiration (recommend 1-2 years before)
5. **Compromise Response**: Have incident response plan for suspected private key compromise

---

## Troubleshooting

### Form Validation Errors

**Problem**: Red error messages appear below fields

**Solution**: Fix highlighted fields:
- Common Name: Required, 1-64 characters
- Country: Optional, but if provided must be exactly 2 uppercase letters (e.g., `US`)
- Password: 12+ chars with uppercase, lowercase, and digit

---

### CA Creation Takes Too Long

**Problem**: "Generating Keys..." persists > 30 seconds

**Possible Causes**:
- RSA 8192 key generation on slow hardware
- System resource constraints

**Solutions**:
1. Wait (RSA 8192 can take 10-30 seconds on some systems)
2. If timeout occurs, try:
   - Smaller key size (RSA 4096 instead of 8192)
   - Different algorithm (ECDSA P-384 or Ed25519)
   - Check system CPU/memory availability

---

### Password Rejected Despite Meeting Requirements

**Problem**: "Password does not meet complexity requirements"

**Checklist**:
- [ ] At least 12 characters long?
- [ ] Contains uppercase letter (A-Z)?
- [ ] Contains lowercase letter (a-z)?
- [ ] Contains digit (0-9)?
- [ ] Password and confirmation match exactly?

**Example valid password**: `SecureCA2025!`

---

## Frequently Asked Questions

### Q: Can I change the CA password after creation?

**A**: No. The password is only used during initial key encryption. To change encryption:
1. Create new CA with new password
2. Re-issue all certificates under new CA
3. Revoke old CA

### Q: What happens if I lose the encryption password?

**A**: The encrypted private key becomes permanently inaccessible. You cannot:
- Decrypt the key
- Use the CA to sign certificates
- Recover the password

**Mitigation**: Always back up password securely and test recovery procedures.

### Q: Can I have multiple CAs with same Common Name?

**A**: No. Common Names must be unique within the system. Add qualifiers like year or version:
- ❌ `Root CA` (duplicate)
- ✅ `Root CA 2025`
- ✅ `Root CA v2`

### Q: Which key type should I choose?

**A**: Depends on your requirements:

| Requirement | Recommendation |
|-------------|----------------|
| Maximum compatibility | RSA 4096 |
| Best security/performance balance | ECDSA P-384 |
| Cutting-edge security | Ed25519 |
| Legacy system support | RSA 2048 |
| Compliance (PCI DSS) | RSA 4096 or ECDSA P-384 |

### Q: How long does CA creation take?

**A**: Typical times:
- Ed25519: < 1 second
- RSA 2048: 1 second
- RSA 4096: 2-3 seconds
- ECDSA P-384: 1-2 seconds
- RSA 8192: 5-30 seconds (depending on hardware)

### Q: Can I create CA without logging in?

**A**: No. CA creation requires authenticated admin access. All operations are logged with user ID for security audit trail.

---

## Support

For technical support or questions:
- **Documentation**: See project CLAUDE.md and PKI module documentation
- **Issues**: Report bugs at project issue tracker
- **Security**: Report security concerns to security team (DO NOT use public issue tracker)

---

**Document Version**: 1.0
**Feature Version**: 001-enhance-pki-ca-form
**Last Updated**: 2025-11-25
