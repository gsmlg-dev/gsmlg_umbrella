# Data Model: Enhanced PKI CA Creation Form

**Feature**: 001-enhance-pki-ca-form
**Date**: 2025-11-18
**Purpose**: Define data structures, entities, and relationships for the enhanced CA creation form

## Overview

This feature introduces enhancements to the Certificate Authority data model to support multiple key types, encrypted private keys, and structured subject information. The core entity is the `CertificateAuthority`, which is extended with new fields while maintaining backward compatibility.

## Entities

### 1. CertificateAuthority (Extended)

**Table**: `certificate_authorities`

**Purpose**: Represents a PKI Certificate Authority with its cryptographic configuration and metadata.

**New Fields**:
- `key_type` (string): Algorithm used for CA key pair ('rsa', 'ecdsa', 'ed25519')
- `key_algorithm_details` (jsonb): Algorithm-specific metadata (e.g., curve name for ECDSA)
- `private_key_encrypted` (boolean): Indicates if private key PEM is password-encrypted

**Existing Fields** (for reference):
- `id` (uuid): Primary key
- `subject` (text): X.509 Distinguished Name
- `certificate_der` (binary): DER-encoded certificate
- `private_key_pem` (text): PEM-encoded private key (may be encrypted)
- `not_before` (datetime): Validity start
- `not_after` (datetime): Validity end
- `serial` (string): Certificate serial number
- `status` (string): CA status ('active', 'revoked', 'expired')
- `inserted_at` (datetime): Record creation time
- `updated_at` (datetime): Record last update time

**Schema Definition**:

```elixir
defmodule GSMLG.PKI.Schema.CertificateAuthority do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "certificate_authorities" do
    field :subject, :string
    field :certificate_der, :binary
    field :private_key_pem, :string
    field :not_before, :utc_datetime
    field :not_after, :utc_datetime
    field :serial, :string
    field :status, :string
    
    # New fields
    field :key_type, :string, default: "rsa"
    field :key_algorithm_details, :map
    field :private_key_encrypted, :boolean, default: false

    timestamps()
  end

  def changeset(ca, attrs) do
    ca
    |> cast(attrs, [
      :subject, :certificate_der, :private_key_pem,
      :not_before, :not_after, :serial, :status,
      :key_type, :key_algorithm_details, :private_key_encrypted
    ])
    |> validate_required([:subject, :certificate_der, :private_key_pem, 
                          :not_before, :not_after, :serial, :key_type])
    |> validate_inclusion(:key_type, ["rsa", "ecdsa", "ed25519"])
    |> validate_inclusion(:status, ["active", "revoked", "expired"])
    |> unique_constraint(:serial)
  end
end
```

**Relationships**:
- Has many: `Certificate` (certificates issued by this CA)
- Has many: `CAEvent` (audit log events)

**Indexes**:
- `serial` (unique): Fast lookup by serial number
- `status`: Filter active/revoked/expired CAs
- `not_after`: Query expiring CAs

### 2. CAFormData (Virtual/Embedded)

**Purpose**: Represents form input data for CA creation, validated before conversion to CertificateAuthority entity.

**Not Persisted**: This is an embedded schema used only for form validation in LiveView.

**Fields**:
- `common_name` (string): CN component of subject DN (required, 1-64 chars)
- `organization` (string): O component (optional, max 64 chars)
- `organizational_unit` (string): OU component (optional, max 64 chars)
- `country` (string): C component (optional, exactly 2 uppercase letters)
- `state` (string): ST component (optional, max 128 chars)
- `locality` (string): L component (optional, max 128 chars)
- `key_type` (string): Key algorithm ('rsa', 'ecdsa', 'ed25519')
- `key_size` (integer): Key size in bits (valid values depend on key_type)
- `validity_start` (datetime): Certificate validity start
- `validity_end` (datetime): Certificate validity end
- `encrypt_key` (boolean): Whether to encrypt private key
- `password` (string, virtual): Password for key encryption (not stored)
- `password_confirmation` (string, virtual): Password confirmation (not stored)

**Schema Definition**:

```elixir
defmodule GSMLG.AdminWeb.PKILive.CALive.FormData do
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :common_name, :string
    field :organization, :string
    field :organizational_unit, :string
    field :country, :string
    field :state, :string
    field :locality, :string
    field :key_type, :string, default: "rsa"
    field :key_size, :integer, default: 4096
    field :validity_start, :utc_datetime
    field :validity_end, :utc_datetime
    field :encrypt_key, :boolean, default: false
    field :password, :string, virtual: true
    field :password_confirmation, :string, virtual: true
  end

  def changeset(form_data, attrs) do
    form_data
    |> cast(attrs, [
      :common_name, :organization, :organizational_unit,
      :country, :state, :locality, :key_type, :key_size,
      :validity_start, :validity_end, :encrypt_key,
      :password, :password_confirmation
    ])
    |> validate_required([:common_name, :key_type, :key_size, 
                          :validity_start, :validity_end])
    |> validate_length(:common_name, min: 1, max: 64)
    |> validate_length(:organization, max: 64)
    |> validate_length(:organizational_unit, max: 64)
    |> validate_length(:country, is: 2)
    |> validate_format(:country, ~r/^[A-Z]{2}$/, 
         message: "must be 2 uppercase letters (ISO 3166-1 alpha-2)")
    |> validate_length(:state, max: 128)
    |> validate_length(:locality, max: 128)
    |> validate_inclusion(:key_type, ["rsa", "ecdsa", "ed25519"])
    |> validate_key_size()
    |> validate_datetime_range()
    |> validate_password_if_encrypted()
  end

  defp validate_key_size(changeset) do
    key_type = get_field(changeset, :key_type)
    key_size = get_field(changeset, :key_size)

    valid_sizes = case key_type do
      "rsa" -> [2048, 3072, 4096, 8192]
      "ecdsa" -> [256, 384, 521]
      "ed25519" -> [256]  # Fixed size
      _ -> []
    end

    if key_size in valid_sizes do
      changeset
    else
      add_error(changeset, :key_size, 
        "invalid size for #{key_type} (valid: #{inspect(valid_sizes)})")
    end
  end

  defp validate_datetime_range(changeset) do
    start_dt = get_field(changeset, :validity_start)
    end_dt = get_field(changeset, :validity_end)

    cond do
      is_nil(start_dt) or is_nil(end_dt) ->
        changeset

      DateTime.compare(end_dt, start_dt) != :gt ->
        add_error(changeset, :validity_end, 
          "must be after validity start")

      DateTime.diff(end_dt, start_dt, :day) > 7300 ->
        # Warning for > 20 years (7300 days)
        put_change(changeset, :validity_warning, 
          "Validity period longer than recommended 20 years")

      true ->
        changeset
    end
  end

  defp validate_password_if_encrypted(changeset) do
    encrypt_key = get_field(changeset, :encrypt_key)
    password = get_field(changeset, :password)
    password_confirmation = get_field(changeset, :password_confirmation)

    if encrypt_key do
      changeset
      |> validate_required([:password, :password_confirmation])
      |> validate_length(:password, min: 12, 
           message: "must be at least 12 characters")
      |> validate_confirmation(:password, 
           message: "does not match password")
    else
      changeset
    end
  end
end
```

### 3. KeyAlgorithmDetails (JSON Structure)

**Purpose**: Stores algorithm-specific metadata in the `key_algorithm_details` JSONB field.

**Structure varies by key_type**:

**For RSA**:
```json
{
  "public_exponent": 65537,
  "modulus_bits": 4096
}
```

**For ECDSA**:
```json
{
  "curve_name": "secp384r1",
  "curve_oid": "1.3.132.0.34"
}
```

**For Ed25519**:
```json
{
  "curve_name": "ed25519",
  "key_size_bits": 256
}
```

**Access Pattern**:
```elixir
# Store
ca = %CertificateAuthority{
  key_type: "ecdsa",
  key_algorithm_details: %{
    "curve_name" => "secp384r1",
    "curve_oid" => "1.3.132.0.34"
  }
}

# Retrieve
curve_name = ca.key_algorithm_details["curve_name"]
```

## Data Transformations

### Form Data → Subject DN String

**Transformation**: Individual subject fields → X.509 Distinguished Name string

```elixir
defmodule GSMLG.PKI.SubjectBuilder do
  def build_dn(form_data) do
    components = [
      {"CN", form_data.common_name},
      {"O", form_data.organization},
      {"OU", form_data.organizational_unit},
      {"C", form_data.country},
      {"ST", form_data.state},
      {"L", form_data.locality}
    ]
    
    components
    |> Enum.reject(fn {_, value} -> is_nil(value) or value == "" end)
    |> Enum.map(fn {key, value} -> "/#{key}=#{value}" end)
    |> Enum.join("")
  end
end

# Example:
# Input: %{common_name: "Example CA", organization: "Example Corp", country: "US"}
# Output: "/CN=Example CA/O=Example Corp/C=US"
```

### Key Type Selection → Available Key Sizes

**Transformation**: Key type string → list of valid key sizes

```elixir
def available_key_sizes(key_type) do
  case key_type do
    "rsa" -> [2048, 3072, 4096, 8192]
    "ecdsa" -> [256, 384, 521]
    "ed25519" -> []  # Fixed, no selection
    _ -> []
  end
end
```

### DateTime Range → Validity Period

**Transformation**: Start/end datetimes → certificate validity fields

```elixir
# Form provides: validity_start, validity_end (DateTime structs)
# Stored as: not_before, not_after (utc_datetime fields)
%CertificateAuthority{
  not_before: form_data.validity_start,
  not_after: form_data.validity_end
}
```

## State Transitions

### CertificateAuthority Status

```
[Created] --> active
            (CA initialized successfully)

active --> revoked
        (Manual revocation or key compromise)

active --> expired
        (DateTime.utc_now() > not_after)

expired --> (terminal state)
revoked --> (terminal state)
```

**Validation Rules**:
- Cannot create certificate with revoked/expired CA
- Cannot reactivate revoked/expired CA
- Status transitions logged in CAEvent table

## Database Migration

**Migration File**: `priv/repo/migrations/YYYYMMDDHHMMSS_add_key_type_to_certificate_authorities.exs`

```elixir
defmodule GSMLG.Repo.Migrations.AddKeyTypeToCertificateAuthorities do
  use Ecto.Migration

  def up do
    alter table(:certificate_authorities) do
      add :key_type, :string, null: false, default: "rsa"
      add :key_algorithm_details, :map
      add :private_key_encrypted, :boolean, null: false, default: false
    end

    create index(:certificate_authorities, [:key_type])
  end

  def down do
    alter table(:certificate_authorities) do
      remove :key_type
      remove :key_algorithm_details
      remove :private_key_encrypted
    end
  end
end
```

**Backward Compatibility**:
- Default `key_type` to "rsa" for existing CAs
- `key_algorithm_details` nullable for existing records
- `private_key_encrypted` defaults to `false` (existing keys are unencrypted)

## Validation Rules Summary

### Subject Fields
- **Common Name (CN)**: Required, 1-64 characters
- **Organization (O)**: Optional, max 64 characters
- **Organizational Unit (OU)**: Optional, max 64 characters
- **Country (C)**: Optional, exactly 2 uppercase letters (ISO 3166-1 alpha-2)
- **State/Province (ST)**: Optional, max 128 characters
- **Locality (L)**: Optional, max 128 characters

### Key Configuration
- **Key Type**: Must be one of: 'rsa', 'ecdsa', 'ed25519'
- **Key Size**: Must be valid for selected key type
  - RSA: 2048, 3072, 4096, 8192
  - ECDSA: 256, 384, 521
  - Ed25519: 256 (fixed)

### Validity Period
- **Start DateTime**: Required, must be valid UTC datetime
- **End DateTime**: Required, must be after start datetime
- **Warning Threshold**: Warn if period > 7300 days (20 years)

### Private Key Encryption
- **Password**: Required if encrypt_key=true, minimum 12 characters
- **Password Confirmation**: Must match password
- **Storage**: Password never persisted, only used during key encryption

## Data Access Patterns

### Create CA

```elixir
# LiveView calls PKIContext
PKIContext.initialize_ca(subject_dn, opts)

# PKIContext calls GSMLG.PKI.CA
GSMLG.PKI.CA.initialize(subject_dn, opts)

# CA module creates entity
%CertificateAuthority{
  subject: subject_dn,
  key_type: opts[:key_type],
  key_size: opts[:key_size],
  key_algorithm_details: build_algorithm_details(opts),
  private_key_encrypted: opts[:encrypt_key],
  private_key_pem: generate_key_pem(opts),
  certificate_der: sign_certificate(key, subject_dn, validity),
  not_before: opts[:validity_start],
  not_after: opts[:validity_end],
  status: "active"
}
|> Repo.insert()
```

### Query Active CAs

```elixir
from(ca in CertificateAuthority,
  where: ca.status == "active",
  where: ca.not_after > ^DateTime.utc_now(),
  order_by: [desc: ca.inserted_at])
|> Repo.all()
```

### Query CAs by Key Type

```elixir
from(ca in CertificateAuthority,
  where: ca.key_type == ^key_type,
  where: ca.status == "active")
|> Repo.all()
```

## Examples

### Complete CA Creation Flow

```elixir
# 1. User submits form
form_params = %{
  "common_name" => "Example Root CA",
  "organization" => "Example Corp",
  "country" => "US",
  "key_type" => "ecdsa",
  "key_size" => "384",
  "validity_start" => "2025-11-18T00:00:00Z",
  "validity_end" => "2035-11-18T00:00:00Z",
  "encrypt_key" => "true",
  "password" => "secure_password_123",
  "password_confirmation" => "secure_password_123"
}

# 2. Validate form data
changeset = CALive.FormData.changeset(%CALive.FormData{}, form_params)

if changeset.valid? do
  # 3. Transform to subject DN
  subject_dn = SubjectBuilder.build_dn(changeset.data)
  # => "/CN=Example Root CA/O=Example Corp/C=US"
  
  # 4. Build CA creation options
  opts = [
    key_type: :ecdsa,
    key_size: 384,
    validity_start: ~U[2025-11-18 00:00:00Z],
    validity_end: ~U[2035-11-18 00:00:00Z],
    encrypt_key: true,
    password: "secure_password_123",
    actor: "admin@example.com"
  ]
  
  # 5. Create CA
  {:ok, ca} = PKIContext.initialize_ca(subject_dn, opts)
  
  # 6. Resulting entity
  %CertificateAuthority{
    id: "550e8400-e29b-41d4-a716-446655440000",
    subject: "/CN=Example Root CA/O=Example Corp/C=US",
    key_type: "ecdsa",
    key_algorithm_details: %{"curve_name" => "secp384r1"},
    private_key_encrypted: true,
    private_key_pem: "-----BEGIN ENCRYPTED PRIVATE KEY-----\n...",
    certificate_der: <<48, 130, 3, 82, ...>>,
    not_before: ~U[2025-11-18 00:00:00Z],
    not_after: ~U[2035-11-18 00:00:00Z],
    serial: "A1B2C3D4E5F6",
    status: "active",
    inserted_at: ~U[2025-11-18 12:34:56Z],
    updated_at: ~U[2025-11-18 12:34:56Z]
  }
end
```

## References

- [X.509 Distinguished Name Components](https://www.itu.int/rec/T-REC-X.520)
- [Ecto Changesets Documentation](https://hexdocs.pm/ecto/Ecto.Changeset.html)
- [Ecto Embedded Schemas](https://hexdocs.pm/ecto/Ecto.Schema.html#embedded_schema/1)
- [ISO 3166-1 alpha-2 Country Codes](https://en.wikipedia.org/wiki/ISO_3166-1_alpha-2)
