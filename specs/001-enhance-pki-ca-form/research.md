# Research: Enhanced PKI CA Creation Form

**Feature**: 001-enhance-pki-ca-form
**Date**: 2025-11-18
**Purpose**: Technical research and decision documentation for implementing enhanced CA creation form

## Executive Summary

This document consolidates technical research for enhancing the PKI CA creation form. Key decisions include:
- Using LiveView change events for dynamic key size options based on key type selection
- Implementing datetime range picker as a custom LiveView component (phoenix_duskmoon doesn't include one)
- Extending X509 Elixir library capabilities for ECDSA and Ed25519 support
- Adding encrypted private key storage using PKCS#8 encryption

## Current State Analysis

### Existing Implementation

**Location**: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/pki_live/ca_live/index.ex`

**Current Form Fields**:
- Subject DN: Single text input with DN string format (e.g., `/C=US/O=Example/CN=CA`)
- Key Type: Dropdown with RSA and EC options
- Key Size: Dropdown with 2048, 3072, 4096 options
- Validity: Number input for days (1-7300)

**Limitations**:
1. Subject DN as single string - hard to validate individual components
2. Only RSA and EC key types (no Ed25519)
3. Key size options don't update dynamically when key type changes
4. Validity as days count, not datetime range
5. No private key encryption option
6. Uses plain HTML form-control classes, not phoenix_duskmoon components

### Technology Stack

**Phoenix LiveView**: 0.20+ (included in Phoenix 1.7+)
- Supports `phx-change` events for real-time form updates
- Form validation via changesets
- Assigns for reactive state management

**phoenix_duskmoon**: v7.0
- DaisyUI-based component library
- Available components: `dm_input`, `dm_select`, `dm_checkbox`, `dm_form`, `dm_button`
- **Missing**: datetime range picker (needs custom implementation)

**X509 Elixir Library**: Current version in deps
- Supports RSA key generation
- ECDSA support via `:public_key` Erlang module
- Ed25519 requires additional Erlang crypto functions

## Research Findings

### 1. Individual Subject Field Inputs

**Decision**: Break DN string into 6 separate inputs (CN, O, OU, C, ST, L)

**Rationale**:
- Easier validation (country code must be 2 letters, CN required, etc.)
- Better UX - clear labels and field-specific help text
- Prevents malformed DN strings
- Aligns with X.509 standard field definitions

**Implementation Approach**:
```elixir
# LiveView assigns structure
subject_fields: %{
  "common_name" => "",
  "organization" => "",
  "organizational_unit" => "",
  "country" => "",
  "state" => "",
  "locality" => ""
}
```

**Validation Rules**:
- CN: Required, 1-64 characters
- O: Optional, max 64 characters
- OU: Optional, max 64 characters
- C: Optional, exactly 2 uppercase letters (ISO 3166-1 alpha-2)
- ST: Optional, max 128 characters
- L: Optional, max 128 characters

**Alternatives Considered**:
- Keep single DN string: Rejected due to poor UX and validation complexity
- Use nested form with add/remove fields: Rejected as over-engineering for fixed X.509 fields

### 2. Key Type and Dynamic Key Size Selection

**Decision**: Use LiveView `phx-change` event on key type selector to update available key sizes

**Rationale**:
- Different algorithms have different valid key sizes
- Dynamic updates provide immediate feedback
- No page reload required (LiveView handles reactivity)

**Key Type to Key Size Mapping**:
- **RSA**: 2048, 3072, 4096, 8192 bits
- **ECDSA**: 256 (P-256), 384 (P-384), 521 (P-521) bits
- **Ed25519**: Fixed 256 bits (no selection needed, hide key size field)

**Implementation Approach**:
```elixir
def handle_event("key_type_changed", %{"key_type" => key_type}, socket) do
  available_sizes = case key_type do
    "rsa" -> [2048, 3072, 4096, 8192]
    "ecdsa" -> [256, 384, 521]
    "ed25519" -> []  # Fixed, no selection
  end
  
  default_size = List.first(available_sizes)
  
  {:noreply, socket
    |> assign(:key_type, key_type)
    |> assign(:available_key_sizes, available_sizes)
    |> assign(:key_size, default_size)}
end
```

**Alternatives Considered**:
- JavaScript-based hiding: Rejected to keep LiveView-first approach
- Show all sizes always: Rejected due to invalid combinations (e.g., 8192-bit ECDSA)

### 3. DateTime Range Selector Component

**Decision**: Implement custom LiveView component `DateTimeRangePicker` using HTML5 datetime-local inputs

**Rationale**:
- phoenix_duskmoon doesn't include datetime range picker
- HTML5 `datetime-local` input provides native browser UI
- LiveView validation can ensure end > start
- No heavy JavaScript dependencies needed

**Component Structure**:
```elixir
defmodule GSMLG.AdminWeb.PKILive.Components.DateTimeRangePicker do
  use GSMLG.AdminWeb, :html
  
  attr :id, :string, required: true
  attr :start_value, :any, default: nil
  attr :end_value, :any, default: nil
  attr :on_change, :string, default: "datetime_range_changed"
  
  def datetime_range_picker(assigns)
end
```

**Default Values**:
- Start: Current datetime (DateTime.utc_now())
- End: Current datetime + 10 years (default CA lifetime)

**Validation**:
- End must be after start
- Warn if range > 20 years (per spec clarification)
- Both fields required

**Alternatives Considered**:
- Third-party JS datepicker: Rejected to avoid Bun/npm dependencies and align with LiveView-first approach
- Separate date and time inputs: Rejected as HTML5 datetime-local provides better UX
- Calendar popup widget: Rejected as unnecessary complexity for admin tool

### 4. Private Key Encryption

**Decision**: Use PKCS#8 encryption with password-based encryption (PBE) via `:public_key.pem_entry_encode/3`

**Rationale**:
- PKCS#8 is industry standard for encrypted private keys
- Erlang `:public_key` module supports PBE encryption
- Compatible with OpenSSL and other PKI tools
- Password stored only in session, never persisted

**Encryption Algorithm**: AES-256-CBC with PBKDF2 (default in Erlang :public_key)

**Implementation Approach**:
```elixir
# In GSMLG.PKI.CA module
def generate_encrypted_key(key_type, key_size, password) do
  # Generate key
  private_key = generate_key(key_type, key_size)
  
  # Encrypt with password
  pem_entry = :public_key.pem_entry_encode(:PrivateKeyInfo, private_key, 
    cipher: {:aes_256_cbc, password})
    
  {:ok, :public_key.pem_encode([pem_entry])}
end
```

**UI Flow**:
1. Checkbox: "Encrypt Private Key"
2. When checked, show two password fields (password, confirmation)
3. Validate password strength (min 12 characters, warn if weak)
4. Validate passwords match
5. Pass password to CA creation function
6. Password never stored in database

**Alternatives Considered**:
- HSM integration: Rejected as over-engineering for MVP (can add later)
- Keystore/vault integration: Rejected to keep feature scope manageable
- Plain text keys: Rejected due to security best practices

### 5. Form Validation Strategy

**Decision**: Use Ecto changeset validation with LiveView form integration

**Rationale**:
- Ecto changesets provide structured validation
- LiveView `phx-change` allows real-time validation feedback
- Consistent with existing Phoenix conventions

**Validation Layers**:
1. **Client-side** (HTML5): Required fields, input types, min/max values
2. **LiveView changeset**: Field format, cross-field validation
3. **Business logic** (GSMLG.PKI): Key generation success, DN uniqueness

**Changeset Structure**:
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
    field :key_type, :string
    field :key_size, :integer
    field :validity_start, :utc_datetime
    field :validity_end, :utc_datetime
    field :encrypt_key, :boolean, default: false
    field :password, :string, virtual: true
    field :password_confirmation, :string, virtual: true
  end
  
  def changeset(form_data, attrs) do
    form_data
    |> cast(attrs, [...])
    |> validate_required([:common_name, :key_type, :key_size, :validity_start, :validity_end])
    |> validate_length(:common_name, min: 1, max: 64)
    |> validate_length(:country, is: 2)
    |> validate_format(:country, ~r/^[A-Z]{2}$/)
    |> validate_datetime_range()
    |> validate_password_if_encrypted()
  end
end
```

**Alternatives Considered**:
- Manual validation functions: Rejected due to lack of structure and reusability
- JavaScript validation library: Rejected to keep LiveView-first approach

## Technology Decisions

### Phoenix DuskMoon Component Mapping

| Form Element | phoenix_duskmoon Component | Notes |
|--------------|---------------------------|-------|
| Text inputs (CN, O, OU, etc.) | `<.dm_input type="text">` | Standard text input with label and validation |
| Select dropdowns (key type) | `<.dm_select>` | Dropdown with options |
| Number input (key size) | `<.dm_select>` | Use select for predefined sizes, not free-form number input |
| DateTime range | Custom component | HTML5 `datetime-local` inputs styled with TailwindCSS |
| Checkbox (encrypt key) | `<.dm_checkbox>` | Toggle encryption option |
| Password inputs | `<.dm_input type="password">` | Password and confirmation fields |
| Submit button | `<.dm_button type="submit">` | Primary action button |
| Form wrapper | `<.dm_form>` | LiveView form with phx-submit and phx-change |

### Database Schema Changes

**New fields for `certificate_authorities` table**:
```sql
ALTER TABLE certificate_authorities
ADD COLUMN key_type VARCHAR(20) NOT NULL DEFAULT 'rsa',
ADD COLUMN key_algorithm_details JSONB,  -- Store curve name for ECDSA, etc.
ADD COLUMN private_key_encrypted BOOLEAN NOT NULL DEFAULT false;
```

**Rationale**:
- `key_type`: Store algorithm (rsa/ecdsa/ed25519) for audit and display
- `key_algorithm_details`: JSON for algorithm-specific metadata (e.g., curve name for ECDSA)
- `private_key_encrypted`: Flag indicating if private key PEM is encrypted (password not stored)

## Implementation Dependencies

### Elixir Libraries

1. **X509** (already in deps): Core PKI operations
   - RSA key generation: ✅ Supported
   - ECDSA key generation: ✅ Supported via `:public_key`
   - Ed25519: ⚠️ Requires Erlang/OTP 24+ with crypto support

2. **Ecto**: Database and validation
   - Changesets for form validation
   - Schema migrations for new fields

3. **Phoenix.LiveView**: Reactive UI
   - `phx-change` for key type selection
   - `phx-submit` for form submission
   - Assigns for dynamic key size options

### Erlang/OTP Modules

1. **:public_key**: Private key encryption
   - `pem_entry_encode/3` for PKCS#8 encryption
   - `pem_decode/1` and `pem_encode/1` for PEM format

2. **:crypto**: Ed25519 support (OTP 24+)
   - `generate_key(:eddsa, :ed25519)` for Ed25519 key pairs

## Testing Strategy

### Unit Tests (apps/gsmlg/test/)

1. `GSMLG.PKI.KeyGenerator` tests:
   - Generate RSA keys (2048, 3072, 4096, 8192 bits)
   - Generate ECDSA keys (P-256, P-384, P-521 curves)
   - Generate Ed25519 keys
   - Encrypt keys with password
   - Decrypt encrypted keys

2. `GSMLG.PKI.CA` tests:
   - Create CA with new key types
   - Validate encrypted key storage
   - Ensure backward compatibility with existing CAs

### Integration Tests (apps/gsmlg_admin_web/test/)

1. `CALive.Index` LiveView tests:
   - Render CA creation form
   - Change key type, verify key size options update
   - Submit form with valid data
   - Submit form with invalid data (validation errors)
   - Test encrypted key checkbox workflow
   - Test datetime range validation

2. Form validation tests:
   - Individual subject field validation
   - Country code format validation
   - DateTime range validation (end > start)
   - Password strength validation
   - Password confirmation matching

## Performance Considerations

**Form Rendering**: Estimated 15-20 form fields
- Expected render time: <100ms (well under 300ms goal)
- LiveView change events: <50ms response time for key type changes

**CA Creation**: Includes key generation + certificate signing
- RSA 2048: ~100-200ms
- RSA 4096: ~500-800ms
- ECDSA: ~50-100ms (faster than RSA)
- Ed25519: ~10-20ms (fastest)
- Encryption overhead: +50-100ms for password-based encryption

**Optimization**: All within 3-second target for CA creation

## Security Considerations

1. **Password Handling**:
   - Password only in LiveView assigns (never persisted)
   - Transmitted over HTTPS only
   - Cleared from assigns after CA creation
   - User responsible for storing password securely

2. **Key Storage**:
   - Encrypted keys stored as PEM in database
   - Encryption uses strong algorithm (AES-256-CBC, PBKDF2)
   - No key escrow (password required for future use)

3. **Validation**:
   - Server-side validation prevents DN injection
   - Country code whitelist (ISO 3166-1 alpha-2)
   - Maximum field lengths prevent DoS via large inputs

## Open Questions & Resolutions

All technical unknowns have been resolved through this research phase. No blocking issues identified.

## Appendix: Code Examples

### A. LiveView Form Structure

```heex
<.dm_form for={@form} phx-submit="create_ca" phx-change="validate_form">
  <!-- Subject Fields -->
  <div class="grid grid-cols-2 gap-4">
    <.dm_input field={@form[:common_name]} label="Common Name (CN)" required />
    <.dm_input field={@form[:organization]} label="Organization (O)" />
    <.dm_input field={@form[:organizational_unit]} label="Organizational Unit (OU)" />
    <.dm_input field={@form[:country]} label="Country (C)" maxlength="2" placeholder="US" />
    <.dm_input field={@form[:state]} label="State/Province (ST)" />
    <.dm_input field={@form[:locality]} label="Locality (L)" />
  </div>
  
  <!-- Key Configuration -->
  <.dm_select field={@form[:key_type]} label="Key Type" phx-change="key_type_changed"
    options={[{"RSA", "rsa"}, {"ECDSA", "ecdsa"}, {"Ed25519", "ed25519"}]} />
  
  <%= if @key_type != "ed25519" do %>
    <.dm_select field={@form[:key_size]} label="Key Size (bits)" 
      options={Enum.map(@available_key_sizes, &{to_string(&1), &1})} />
  <% end %>
  
  <!-- DateTime Range -->
  <.datetime_range_picker id="validity" 
    start_value={@form[:validity_start].value}
    end_value={@form[:validity_end].value} />
  
  <!-- Encryption Option -->
  <.dm_checkbox field={@form[:encrypt_key]} label="Encrypt Private Key" />
  
  <%= if @form[:encrypt_key].value do %>
    <.dm_input field={@form[:password]} type="password" label="Password" required />
    <.dm_input field={@form[:password_confirmation]} type="password" label="Confirm Password" required />
  <% end %>
  
  <.dm_button type="submit" color="primary">Create CA</.dm_button>
</.dm_form>
```

### B. Key Generation Module

```elixir
defmodule GSMLG.PKI.KeyGenerator do
  @moduledoc """
  Generates cryptographic key pairs for PKI operations.
  Supports RSA, ECDSA, and Ed25519 algorithms.
  """
  
  def generate_key(:rsa, key_size) when key_size in [2048, 3072, 4096, 8192] do
    :public_key.generate_key({:rsa, key_size, 65537})
  end
  
  def generate_key(:ecdsa, 256), do: :public_key.generate_key({:namedCurve, :secp256r1})
  def generate_key(:ecdsa, 384), do: :public_key.generate_key({:namedCurve, :secp384r1})
  def generate_key(:ecdsa, 521), do: :public_key.generate_key({:namedCurve, :secp521r1})
  
  def generate_key(:ed25519, _key_size) do
    :crypto.generate_key(:eddsa, :ed25519)
  end
  
  def encrypt_key(private_key, password) do
    cipher = {:aes_256_cbc, :crypto.strong_rand_bytes(16)}
    pem_entry = :public_key.pem_entry_encode(:PrivateKeyInfo, private_key, 
      cipher: cipher, passphrase: password)
    :public_key.pem_encode([pem_entry])
  end
end
```

## References

- [X509 Elixir Library Documentation](https://hexdocs.pm/x509)
- [Phoenix LiveView Form Bindings](https://hexdocs.pm/phoenix_live_view/form-bindings.html)
- [Erlang :public_key Module](https://www.erlang.org/doc/man/public_key.html)
- [PKCS#8 Specification (RFC 5208)](https://tools.ietf.org/html/rfc5208)
- [phoenix_duskmoon Component Library](https://hexdocs.pm/phoenix_duskmoon)
- [X.509 Distinguished Name Fields](https://www.itu.int/rec/T-REC-X.509)
