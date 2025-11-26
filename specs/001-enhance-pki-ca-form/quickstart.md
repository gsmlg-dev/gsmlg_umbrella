# Quick Start: Enhanced PKI CA Creation Form

**Feature**: 001-enhance-pki-ca-form
**Date**: 2025-11-18
**Audience**: Developers implementing this feature

## Overview

This guide provides a quick reference for implementing the enhanced PKI CA creation form. Follow these steps to understand the feature structure, key files, and implementation approach.

## Prerequisites

- Elixir 1.15+ and OTP 26+ installed
- Phoenix 1.7+ with LiveView
- MariaDB database running
- Familiarity with Phoenix LiveView and Ecto

## Quick Reference

### Key Files to Create/Modify

**LiveView Module**:
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/pki_live/ca_live/index.ex` (modify)
- Handles form state, validation, and CA creation

**LiveView Template**:
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/pki_live/ca_live/index.html.heex` (modify)
- phoenix_duskmoon components for form UI

**Form Validation**:
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/pki_live/ca_live/form_data.ex` (create)
- Ecto embedded schema for form validation

**Custom Components**:
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/pki_live/components/datetime_range_picker.ex` (create)
- Reusable datetime range selector

**Business Logic**:
- `apps/gsmlg/lib/gsmlg/pki/key_generator.ex` (create)
- Generate RSA/ECDSA/Ed25519 keys with encryption support

**Schema Migration**:
- `apps/gsmlg/priv/repo/migrations/YYYYMMDDHHMMSS_add_key_type_to_certificate_authorities.exs` (create)
- Add new fields to certificate_authorities table

**Tests**:
- `apps/gsmlg/test/gsmlg/pki/key_generator_test.exs` (create)
- `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/pki_live/ca_live/index_test.exs` (modify)

## Implementation Checklist

### Phase 1: Database Schema (30 min)

- [ ] Create migration file for new CA fields
- [ ] Add `key_type`, `key_algorithm_details`, `private_key_encrypted` columns
- [ ] Run migration: `mix ecto.migrate`
- [ ] Update `CertificateAuthority` schema module with new fields
- [ ] Add validation for new fields in changeset

### Phase 2: Form Validation Schema (45 min)

- [ ] Create `CALive.FormData` embedded schema module
- [ ] Add all form fields (subject components, key config, validity, encryption)
- [ ] Implement changeset with validation rules
- [ ] Add custom validators: `validate_key_size/1`, `validate_datetime_range/1`, `validate_password_if_encrypted/1`
- [ ] Write unit tests for form validation

### Phase 3: Key Generation Module (1 hour)

- [ ] Create `GSMLG.PKI.KeyGenerator` module
- [ ] Implement `generate_key/2` for RSA/ECDSA/Ed25519
- [ ] Implement `encrypt_key/2` using PKCS#8
- [ ] Handle algorithm-specific details (curve names, key sizes)
- [ ] Write unit tests for each key type and encryption

### Phase 4: DateTime Range Picker Component (45 min)

- [ ] Create `DateTimeRangePicker` component module
- [ ] Use HTML5 `datetime-local` inputs
- [ ] Style with TailwindCSS for DaisyUI theme
- [ ] Add validation feedback for invalid ranges
- [ ] Calculate default values (now, now + 10 years)
- [ ] Add component test

### Phase 5: LiveView Form Implementation (2 hours)

- [ ] Modify `CALive.Index` mount to initialize form assigns
- [ ] Update `:new` action to provide default form values
- [ ] Implement `handle_event("key_type_changed")` for dynamic key sizes
- [ ] Implement `handle_event("validate_form")` for real-time validation
- [ ] Implement `handle_event("create_ca")` for form submission
- [ ] Add password field visibility toggle based on encrypt_key checkbox
- [ ] Test LiveView events manually

### Phase 6: Template with phoenix_duskmoon (1.5 hours)

- [ ] Replace existing form with `<.dm_form>`
- [ ] Create 6 individual `<.dm_input>` fields for subject components
- [ ] Add `<.dm_select>` for key type with `phx-change` event
- [ ] Add dynamic `<.dm_select>` for key size (conditionally hidden for Ed25519)
- [ ] Integrate `<.datetime_range_picker>` component
- [ ] Add `<.dm_checkbox>` for encrypt_key option
- [ ] Add conditional password fields (`<.dm_input type="password">`)
- [ ] Add submit button (`<.dm_button type="submit">`)
- [ ] Style with TailwindCSS grid layout

### Phase 7: PKI Context API Extension (1 hour)

- [ ] Extend `PKIContext.initialize_ca/2` to accept new opts
- [ ] Add `PKIContext.get_key_size_options/1` helper
- [ ] Update CA creation logic to use `KeyGenerator`
- [ ] Handle encrypted vs unencrypted key storage
- [ ] Store `key_type` and `key_algorithm_details` in DB
- [ ] Update audit logging to include new parameters

### Phase 8: Testing (2 hours)

- [ ] Write unit tests for `KeyGenerator` (all algorithms)
- [ ] Write unit tests for `FormData` changeset validation
- [ ] Write integration tests for LiveView form submission
- [ ] Write integration tests for key type change event
- [ ] Write integration tests for password validation
- [ ] Write tests for datetime range validation
- [ ] Run full test suite: `mix test`
- [ ] Check test coverage: `mix test --cover`

### Phase 9: Manual Testing (1 hour)

- [ ] Start development server: `mix phx.server`
- [ ] Navigate to `/pki/ca/new`
- [ ] Test RSA 2048, 3072, 4096, 8192 key creation
- [ ] Test ECDSA P-256, P-384, P-521 key creation
- [ ] Test Ed25519 key creation (verify no key size selector)
- [ ] Test encrypted key creation with password
- [ ] Test form validation (empty fields, invalid country code, invalid datetime range)
- [ ] Test key type changes (verify key size options update)
- [ ] Verify CA appears in `/pki/ca` list with correct metadata

## Component Structure

### LiveView Assigns

```elixir
socket.assigns = %{
  # Form state
  form: to_form(changeset),               # Phoenix.Component.to_form/1
  changeset: %Ecto.Changeset{},           # Form validation state
  
  # Dynamic key size options
  key_type: "rsa",                        # Selected key type
  available_key_sizes: [2048, 3072, ...], # Valid sizes for selected type
  
  # UI state
  show_password_fields: false,            # Toggle for password inputs
  validity_warning: nil,                  # Warning for long validity periods
  
  # User context
  current_user: %User{},                  # Logged-in admin
  session_id: "...",                      # Session identifier
  
  # Standard LiveView assigns
  live_action: :new,
  page_title: "Initialize New CA",
  active_menu: "pki_ca_new"
}
```

### Event Flow

```
User Action                  LiveView Event              Backend Action
-----------                  --------------              --------------
Select key type       -->    key_type_changed     -->    Update available_key_sizes assign
Fill form fields      -->    validate_form        -->    Run changeset validation
Toggle encrypt_key    -->    validate_form        -->    Show/hide password fields
Submit form           -->    create_ca            -->    PKIContext.initialize_ca/2
                                                    -->    Insert CA record
                                                    -->    Redirect to CA list
```

## Code Snippets

### 1. LiveView mount/3

```elixir
def mount(_params, session, socket) do
  socket = socket
    |> assign_user_from_session(session)
    |> assign(
      page_title: "Certificate Authorities",
      active_menu: "pki_ca_list",
      cas: []
    )
    |> load_cas()
  
  {:ok, socket}
end
```

### 2. LiveView handle_params/3 for :new action

```elixir
defp apply_action(socket, :new, _params) do
  now = DateTime.utc_now()
  default_end = DateTime.add(now, 10 * 365 * 24 * 3600, :second)  # +10 years
  
  form_data = %CALive.FormData{
    key_type: "rsa",
    key_size: 4096,
    validity_start: now,
    validity_end: default_end,
    encrypt_key: false
  }
  
  changeset = CALive.FormData.changeset(form_data, %{})
  
  socket
    |> assign(:page_title, "Initialize New CA")
    |> assign(:form, to_form(changeset))
    |> assign(:changeset, changeset)
    |> assign(:key_type, "rsa")
    |> assign(:available_key_sizes, [2048, 3072, 4096, 8192])
end
```

### 3. Key Type Changed Event Handler

```elixir
def handle_event("key_type_changed", %{"key_type" => key_type}, socket) do
  key_type_atom = String.to_existing_atom(key_type)
  available_sizes = PKIContext.get_key_size_options(key_type_atom)
  default_size = List.first(available_sizes) || 256
  
  # Update changeset with new key type and size
  changeset = socket.assigns.changeset
    |> Ecto.Changeset.put_change(:key_type, key_type)
    |> Ecto.Changeset.put_change(:key_size, default_size)
  
  {:noreply, socket
    |> assign(:key_type, key_type)
    |> assign(:available_key_sizes, available_sizes)
    |> assign(:form, to_form(changeset))
    |> assign(:changeset, changeset)}
end
```

### 4. Form Submission Handler

```elixir
def handle_event("create_ca", params, socket) do
  changeset = CALive.FormData.changeset(%CALive.FormData{}, params)
  
  if changeset.valid? do
    form_data = Ecto.Changeset.apply_changes(changeset)
    subject_dn = build_subject_dn(form_data)
    
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
          |> put_flash(:info, "CA initialized successfully")
          |> push_navigate(to: ~p"/pki/ca")}
      
      {:error, reason} ->
        {:noreply, socket
          |> put_flash(:error, "Failed: #{inspect(reason)}")
          |> assign(:form, to_form(changeset))}
    end
  else
    {:noreply, assign(socket, :form, to_form(changeset))}
  end
end

defp build_subject_dn(form_data) do
  [
    {"CN", form_data.common_name},
    {"O", form_data.organization},
    {"OU", form_data.organizational_unit},
    {"C", form_data.country},
    {"ST", form_data.state},
    {"L", form_data.locality}
  ]
  |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)
  |> Enum.map(fn {k, v} -> "/#{k}=#{v}" end)
  |> Enum.join("")
end
```

### 5. Template Structure (Simplified)

```heex
<div class="card bg-base-100 shadow-xl">
  <div class="card-body">
    <h2 class="card-title">Initialize New Certificate Authority</h2>
    
    <.dm_form for={@form} phx-submit="create_ca" phx-change="validate_form" class="space-y-6">
      <!-- Subject Fields -->
      <div class="space-y-4">
        <h3 class="text-lg font-semibold">Subject Information</h3>
        <div class="grid grid-cols-2 gap-4">
          <.dm_input field={@form[:common_name]} label="Common Name (CN)" required />
          <.dm_input field={@form[:organization]} label="Organization (O)" />
          <.dm_input field={@form[:organizational_unit]} label="Organizational Unit (OU)" />
          <.dm_input field={@form[:country]} label="Country (C)" maxlength="2" placeholder="US" />
          <.dm_input field={@form[:state]} label="State/Province (ST)" />
          <.dm_input field={@form[:locality]} label="Locality (L)" />
        </div>
      </div>
      
      <!-- Key Configuration -->
      <div class="space-y-4">
        <h3 class="text-lg font-semibold">Key Configuration</h3>
        <div class="grid grid-cols-2 gap-4">
          <.dm_select field={@form[:key_type]} label="Key Type" phx-change="key_type_changed"
            options={[{"RSA", "rsa"}, {"ECDSA", "ecdsa"}, {"Ed25519", "ed25519"}]} />
          
          <%= if @key_type != "ed25519" do %>
            <.dm_select field={@form[:key_size]} label="Key Size (bits)"
              options={Enum.map(@available_key_sizes, &{to_string(&1), &1})} />
          <% end %>
        </div>
      </div>
      
      <!-- Validity Period -->
      <div class="space-y-4">
        <h3 class="text-lg font-semibold">Validity Period</h3>
        <.datetime_range_picker
          id="validity"
          start_field={@form[:validity_start]}
          end_field={@form[:validity_end]} />
      </div>
      
      <!-- Private Key Encryption -->
      <div class="space-y-4">
        <h3 class="text-lg font-semibold">Private Key Security</h3>
        <.dm_checkbox field={@form[:encrypt_key]} label="Encrypt private key with password" />
        
        <%= if Ecto.Changeset.get_field(@changeset, :encrypt_key) do %>
          <div class="grid grid-cols-2 gap-4">
            <.dm_input field={@form[:password]} type="password" label="Password" required />
            <.dm_input field={@form[:password_confirmation]} type="password" label="Confirm Password" required />
          </div>
          <p class="text-sm text-gray-600">
            Password must be at least 12 characters. It will NOT be stored - you must remember it.
          </p>
        <% end %>
      </div>
      
      <!-- Submit -->
      <div class="card-actions justify-end">
        <.dm_button type="submit" color="primary" size="lg">Initialize CA</.dm_button>
      </div>
    </.dm_form>
  </div>
</div>
```

## Testing Quick Commands

```bash
# Run all tests
mix test

# Run specific test file
mix test apps/gsmlg/test/gsmlg/pki/key_generator_test.exs

# Run LiveView tests
mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/live/pki_live/

# Check test coverage
mix test --cover

# Format code
mix format

# Check code quality
mix credo --strict

# Compile and run
mix compile && mix phx.server
```

## Common Troubleshooting

### Issue: Key size options not updating when key type changes
**Solution**: Verify `phx-change="key_type_changed"` is on the key_type select element, not the form. The event must target the specific field.

### Issue: Form validation errors not displaying
**Solution**: Ensure `<.dm_input field={@form[:field_name]}>` uses the `field` assign, not `name`. phoenix_duskmoon components need the field struct for error display.

### Issue: Password fields showing even when encrypt_key is unchecked
**Solution**: Check changeset value, not assign. Use `Ecto.Changeset.get_field(@changeset, :encrypt_key)` not `@encrypt_key`.

### Issue: CA creation fails with "key generation failed"
**Solution**: Verify OTP version supports Ed25519 (OTP 24+). Check `:crypto.supports()` includes `:eddsa`.

### Issue: Datetime range validation failing
**Solution**: Ensure `validity_start` and `validity_end` are `DateTime` structs, not strings. Parse with `DateTime.from_iso8601/1` if needed.

## Next Steps

After implementing the feature:

1. **Code Review**: Submit PR for team review
2. **QA Testing**: Manual testing on staging environment
3. **Documentation**: Update user-facing docs with new CA creation options
4. **Deployment**: Run migration on production, deploy updated code
5. **Monitoring**: Watch telemetry for CA creation success/failure rates

## References

- [Feature Specification](spec.md)
- [Implementation Plan](plan.md)
- [Research Findings](research.md)
- [Data Model](data-model.md)
- [API Contract](contracts/pki_context.md)
- [phoenix_duskmoon Documentation](https://hexdocs.pm/phoenix_duskmoon)
- [Phoenix LiveView Guide](https://hexdocs.pm/phoenix_live_view)
