# PKI Context API Contract

**Feature**: 001-enhance-pki-ca-form
**Module**: `GSMLG.AdminWeb.PKIContext`
**Purpose**: Defines the API contract between LiveView and PKI business logic

## Overview

The PKIContext module provides a facade for PKI operations, translating LiveView form data into PKI domain operations. This contract specifies the extended API to support new key types and encryption options.

## Functions

### initialize_ca/2

**Purpose**: Initialize a new Certificate Authority with specified subject and cryptographic parameters.

**Signature**:
```elixir
@spec initialize_ca(subject :: String.t(), opts :: keyword()) ::
  {:ok, CertificateAuthority.t()} | {:error, term()}
```

**Parameters**:
- `subject` (string): X.509 Distinguished Name (e.g., "/CN=Example CA/O=Example Corp/C=US")
- `opts` (keyword list):
  - `:key_type` (atom, required): Key algorithm - `:rsa`, `:ecdsa`, or `:ed25519`
  - `:key_size` (integer, required): Key size in bits (valid values depend on key_type)
  - `:validity_start` (DateTime, required): Certificate validity start
  - `:validity_end` (DateTime, required): Certificate validity end
  - `:encrypt_key` (boolean, optional, default: false): Whether to encrypt private key
  - `:password` (string, required if encrypt_key=true): Password for key encryption
  - `:actor` (string, optional): Email of admin performing action (for audit log)

**Returns**:
- `{:ok, %CertificateAuthority{}}` on success
- `{:error, reason}` on failure

**Error Cases**:
- `{:error, :invalid_subject}` - Malformed DN string
- `{:error, :duplicate_subject}` - CA with same subject already exists
- `{:error, :invalid_key_type}` - Unsupported key algorithm
- `{:error, :invalid_key_size}` - Key size not valid for algorithm
- `{:error, :invalid_validity}` - End date before start date
- `{:error, :key_generation_failed}` - Failed to generate key pair
- `{:error, :encryption_failed}` - Failed to encrypt private key (if encrypt_key=true)
- `{:error, :certificate_signing_failed}` - Failed to sign CA certificate

**Example Usage**:
```elixir
opts = [
  key_type: :ecdsa,
  key_size: 384,
  validity_start: ~U[2025-11-18 00:00:00Z],
  validity_end: ~U[2035-11-18 00:00:00Z],
  encrypt_key: true,
  password: "secure_password_123",
  actor: "admin@example.com"
]

case PKIContext.initialize_ca("/CN=Example CA/O=Example Corp/C=US", opts) do
  {:ok, ca} ->
    # CA created successfully
    IO.puts("CA ID: #{ca.id}, Serial: #{ca.serial}")
    
  {:error, reason} ->
    # Handle error
    IO.puts("Failed: #{inspect(reason)}")
end
```

**Implementation Notes**:
- Password is used only for encryption, never stored
- Function should clear password from memory after use
- Validity dates stored in UTC
- Serial number auto-generated (hex-encoded random bytes)
- Certificate automatically marked as "active" status

**Side Effects**:
- Inserts record into `certificate_authorities` table
- Creates CAEvent audit log entry
- May trigger telemetry events for monitoring

### get_key_size_options/1

**Purpose**: Get valid key size options for a given key type.

**Signature**:
```elixir
@spec get_key_size_options(key_type :: atom()) :: list(integer())
```

**Parameters**:
- `key_type` (atom): `:rsa`, `:ecdsa`, or `:ed25519`

**Returns**:
- List of valid key sizes in bits

**Example Usage**:
```elixir
PKIContext.get_key_size_options(:rsa)
# => [2048, 3072, 4096, 8192]

PKIContext.get_key_size_options(:ecdsa)
# => [256, 384, 521]

PKIContext.get_key_size_options(:ed25519)
# => []  # Fixed size, no selection needed
```

**Implementation Notes**:
- Used by LiveView to populate key size dropdown dynamically
- Returns empty list for Ed25519 (fixed 256-bit size)

### validate_subject_dn/1

**Purpose**: Validate a subject DN string format before CA creation.

**Signature**:
```elixir
@spec validate_subject_dn(subject :: String.t()) :: 
  {:ok, components :: map()} | {:error, reason :: String.t()}
```

**Parameters**:
- `subject` (string): X.509 Distinguished Name string

**Returns**:
- `{:ok, components}` - Parsed DN components as map
- `{:error, reason}` - Validation error message

**Example Usage**:
```elixir
PKIContext.validate_subject_dn("/CN=Example CA/O=Example Corp/C=US")
# => {:ok, %{"CN" => "Example CA", "O" => "Example Corp", "C" => "US"}}

PKIContext.validate_subject_dn("/CN=")
# => {:error, "CN component cannot be empty"}
```

**Validation Rules**:
- Must start with `/`
- Components in format `/KEY=VALUE`
- No duplicate keys
- CN component required
- Country code must be 2 uppercase letters if present

## LiveView Integration

### Form Submission Flow

```
User submits form
      ↓
LiveView.handle_event("create_ca", params, socket)
      ↓
Validate form with CALive.FormData changeset
      ↓
If valid: Build opts keyword list
      ↓
Call PKIContext.initialize_ca(subject_dn, opts)
      ↓
{:ok, ca}              {:error, reason}
      ↓                       ↓
put_flash(:info)      put_flash(:error)
push_navigate         assign validation errors
```

### LiveView Event Handlers

**Event**: `"create_ca"`
**Params**: Form field values
**Handler**:
```elixir
def handle_event("create_ca", params, socket) do
  changeset = CALive.FormData.changeset(%CALive.FormData{}, params)
  
  if changeset.valid? do
    form_data = Ecto.Changeset.apply_changes(changeset)
    subject_dn = SubjectBuilder.build_dn(form_data)
    
    opts = [
      key_type: String.to_existing_atom(form_data.key_type),
      key_size: form_data.key_size,
      validity_start: form_data.validity_start,
      validity_end: form_data.validity_end,
      encrypt_key: form_data.encrypt_key,
      password: form_data.password,
      actor: socket.assigns.current_user.email
    ]
    
    case PKIContext.initialize_ca(subject_dn, opts) do
      {:ok, _ca} ->
        {:noreply, socket
          |> put_flash(:info, "CA created successfully")
          |> push_navigate(to: ~p"/pki/ca")}
      
      {:error, reason} ->
        {:noreply, socket
          |> put_flash(:error, "Failed: #{inspect(reason)}")}
    end
  else
    {:noreply, assign(socket, :changeset, changeset)}
  end
end
```

**Event**: `"key_type_changed"`
**Params**: `%{"key_type" => key_type}`
**Handler**:
```elixir
def handle_event("key_type_changed", %{"key_type" => key_type}, socket) do
  key_type_atom = String.to_existing_atom(key_type)
  available_sizes = PKIContext.get_key_size_options(key_type_atom)
  default_size = List.first(available_sizes)
  
  {:noreply, socket
    |> assign(:key_type, key_type)
    |> assign(:available_key_sizes, available_sizes)
    |> assign(:selected_key_size, default_size)}
end
```

**Event**: `"validate_form"`
**Params**: Form field values (on `phx-change`)
**Handler**:
```elixir
def handle_event("validate_form", params, socket) do
  changeset = CALive.FormData.changeset(%CALive.FormData{}, params)
  {:noreply, assign(socket, :changeset, changeset)}
end
```

## Security Considerations

### Password Handling
- Password passed to `initialize_ca/2` via opts
- Never stored in database or assigns after CA creation
- Cleared from memory immediately after use
- Only transmitted over HTTPS

### Input Validation
- All inputs validated via Ecto changeset before API call
- Subject DN sanitized to prevent injection attacks
- Key sizes restricted to known-safe values
- DateTime range validated (end > start)

### Audit Logging
- All CA creation attempts logged (success and failure)
- Includes actor email, timestamp, parameters
- Password excluded from audit logs

## Testing Contract

### Unit Tests (PKIContext module)

```elixir
describe "initialize_ca/2" do
  test "creates CA with RSA 4096 key" do
    opts = [
      key_type: :rsa,
      key_size: 4096,
      validity_start: ~U[2025-01-01 00:00:00Z],
      validity_end: ~U[2035-01-01 00:00:00Z],
      actor: "test@example.com"
    ]
    
    assert {:ok, ca} = PKIContext.initialize_ca("/CN=Test CA", opts)
    assert ca.key_type == "rsa"
    assert ca.key_algorithm_details["modulus_bits"] == 4096
    assert ca.private_key_encrypted == false
  end
  
  test "creates CA with encrypted ECDSA P-384 key" do
    opts = [
      key_type: :ecdsa,
      key_size: 384,
      validity_start: ~U[2025-01-01 00:00:00Z],
      validity_end: ~U[2035-01-01 00:00:00Z],
      encrypt_key: true,
      password: "test_password_123",
      actor: "test@example.com"
    ]
    
    assert {:ok, ca} = PKIContext.initialize_ca("/CN=Test CA", opts)
    assert ca.key_type == "ecdsa"
    assert ca.key_algorithm_details["curve_name"] == "secp384r1"
    assert ca.private_key_encrypted == true
    assert String.contains?(ca.private_key_pem, "ENCRYPTED PRIVATE KEY")
  end
  
  test "returns error for invalid key size" do
    opts = [
      key_type: :rsa,
      key_size: 1024,  # Too small
      validity_start: ~U[2025-01-01 00:00:00Z],
      validity_end: ~U[2035-01-01 00:00:00Z]
    ]
    
    assert {:error, :invalid_key_size} = PKIContext.initialize_ca("/CN=Test CA", opts)
  end
end

describe "get_key_size_options/1" do
  test "returns RSA key sizes" do
    assert PKIContext.get_key_size_options(:rsa) == [2048, 3072, 4096, 8192]
  end
  
  test "returns ECDSA key sizes" do
    assert PKIContext.get_key_size_options(:ecdsa) == [256, 384, 521]
  end
  
  test "returns empty list for Ed25519" do
    assert PKIContext.get_key_size_options(:ed25519) == []
  end
end
```

### Integration Tests (LiveView)

```elixir
describe "CA creation form" do
  test "creates CA with valid input", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/pki/ca/new")
    
    form = form(view, "#ca-form", %{
      common_name: "Test CA",
      organization: "Test Org",
      country: "US",
      key_type: "ecdsa",
      key_size: "384",
      validity_start: "2025-11-18T00:00:00Z",
      validity_end: "2035-11-18T00:00:00Z",
      encrypt_key: "false"
    })
    
    render_submit(form)
    
    assert_redirect(view, ~p"/pki/ca")
    assert ca = Repo.get_by(CertificateAuthority, subject: "/CN=Test CA/O=Test Org/C=US")
    assert ca.key_type == "ecdsa"
  end
  
  test "updates key sizes when key type changes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/pki/ca/new")
    
    # Initially RSA selected
    assert view |> element("#key_size option[value='4096']") |> has_element?()
    
    # Change to ECDSA
    view |> element("#key_type") |> render_change(%{key_type: "ecdsa"})
    
    # Should now have ECDSA sizes
    assert view |> element("#key_size option[value='256']") |> has_element?()
    assert view |> element("#key_size option[value='384']") |> has_element?()
    refute view |> element("#key_size option[value='4096']") |> has_element?()
  end
end
```

## API Versioning

**Current Version**: 1.0 (Initial enhanced implementation)

**Backward Compatibility**:
- Existing `initialize_ca/2` calls with only `key_type: :rsa` remain supported
- Default `key_size: 4096` if not specified for RSA
- Default `encrypt_key: false` if not specified
- Default validity period: 10 years from now if not specified

**Future Considerations**:
- Version 1.1: Add hardware security module (HSM) support
- Version 1.2: Add external CA signing (subordinate CA)
- Version 2.0: Breaking change for async CA creation (long-running for large keys)

## References

- [Phoenix LiveView Form Bindings](https://hexdocs.pm/phoenix_live_view/form-bindings.html)
- [Ecto Changesets](https://hexdocs.pm/ecto/Ecto.Changeset.html)
- [X.509 Certificate Structure](https://tools.ietf.org/html/rfc5280)
