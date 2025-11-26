# Implementation Tasks: Enhanced PKI CA Creation Form

**Feature**: 001-enhance-pki-ca-form
**Branch**: `001-enhance-pki-ca-form`
**Created**: 2025-11-25
**Status**: Ready for Implementation

## Overview

This document provides a dependency-ordered task breakdown for implementing the enhanced PKI CA creation form. Tasks are organized by user story to enable independent implementation and testing of each feature increment.

**User Stories (from spec.md)**:
- **P1**: User Story 1 - Create Basic Root CA (core functionality)
- **P2**: User Story 2 - Configure Key Type and Size (cryptographic flexibility)
- **P2**: User Story 3 - Set Custom Validity Period (datetime range selection)
- **P3**: User Story 4 - Encrypt Private Key (optional security enhancement)

**Implementation Strategy**: Follow TDD (Test-First Development) per constitution. Each user story represents an independently testable MVP increment.

---

## Phase 1: Setup & Foundation

**Goal**: Establish database schema and core PKI infrastructure needed by all user stories.

**Duration**: ~1.5 hours

### Database Schema

- [x] T001 Create migration for certificate_authorities table extensions in apps/gsmlg/priv/repo/migrations/YYYYMMDDHHMMSS_add_key_type_to_certificate_authorities.exs
- [x] T002 Add key_type (string, default 'rsa'), key_algorithm_details (jsonb), private_key_encrypted (boolean, default false) columns
- [x] T003 Create index on key_type column for performance
- [x] T004 Run migration with `mix ecto.migrate` and verify schema changes

### Schema Module Updates

- [x] T005 [P] Update CertificateAuthority schema in apps/gsmlg/lib/gsmlg/pki/schema/certificate_authority.ex to include new fields
- [x] T006 [P] Add validation for key_type inclusion in ["rsa", "ecdsa", "ed25519"]
- [x] T007 [P] Add changeset validation for key_algorithm_details structure

### Core PKI Module - Key Generation

- [x] T008 Create KeyGenerator module in apps/gsmlg/lib/gsmlg/pki/key_generator.ex
- [x] T009 Write tests for KeyGenerator in apps/gsmlg/test/gsmlg/pki/key_generator_test.exs (TDD)
- [x] T010 [P] Implement generate_key/2 for RSA (2048, 3072, 4096, 8192 bits)
- [x] T011 [P] Implement generate_key/2 for ECDSA (P-256, P-384, P-521 curves)
- [x] T012 [P] Implement generate_key/2 for Ed25519 (fixed 256 bits)
- [x] T013 Implement encrypt_key/2 using PKCS#8 with password-based encryption
- [x] T014 Run KeyGenerator tests and verify all pass

---

## Phase 2: User Story 1 - Create Basic Root CA (P1)

**Story Goal**: Administrator can create a CA with individual subject field inputs using phoenix_duskmoon components.

**Independent Test**: Fill all required subject fields (CN, O, OU, C, ST, L) in separate inputs, submit form, verify CA created with correct subject DN.

**Success Criteria**: P1 story fully testable and deliverable as MVP.

### Form Validation Schema (TDD)

- [x] T015 [US1] Create CAFormData embedded schema in apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/pki_live/ca_live/form_data.ex
- [x] T016 [US1] Write tests for CAFormData changeset validation in apps/gsmlg_admin_web/test/gsmlg/admin_web/live/pki_live/ca_live/form_data_test.exs
- [x] T017 [P] [US1] Add fields: common_name, organization, organizational_unit, country, state, locality
- [x] T018 [P] [US1] Implement validate_required for common_name
- [x] T019 [P] [US1] Implement validate_length for CN (1-64), O (max 64), OU (max 64), ST (max 128), L (max 128)
- [x] T020 [P] [US1] Implement validate_format for country (exactly 2 uppercase letters, ISO 3166-1 alpha-2)
- [x] T021 [US1] Implement build_subject_dn/1 helper to convert form fields to X.509 DN string
- [x] T022 [US1] Run CAFormData tests and verify all pass

### LiveView Module - Basic Form (TDD)

- [x] T023 [US1] Write LiveView tests for CA creation in apps/gsmlg_admin_web/test/gsmlg/admin_web/live/pki_live/ca_live/index_test.exs
- [x] T024 [US1] Test: Form renders with 6 subject field inputs (CN, O, OU, C, ST, L)
- [x] T025 [US1] Test: Form validates required CN field
- [x] T026 [US1] Test: Form validates country code format (2 letters)
- [x] T027 [US1] Test: Form submission creates CA with correct subject DN
- [x] T028 [US1] Update CALive.Index mount/3 in apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/pki_live/ca_live/index.ex
- [x] T029 [US1] Update apply_action for :new to initialize CAFormData with defaults
- [x] T030 [US1] Implement handle_event("validate_form") for real-time validation
- [x] T031 [US1] Implement handle_event("create_ca") for form submission
- [x] T032 [US1] Integrate with PKIContext.initialize_ca/2 for CA creation
- [x] T033 [US1] Add error handling and flash messages for success/failure
- [x] T034 [US1] Run LiveView tests and verify all pass

### LiveView Template - Basic Form UI

- [x] T035 [US1] Update CA creation form template in apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/pki_live/ca_live/index.html.heex
- [x] T036 [US1] Replace existing form with <.dm_form for={@form} phx-submit="create_ca" phx-change="validate_form">
- [x] T037 [P] [US1] Add <.dm_input field={@form[:common_name]} label="Common Name (CN)" required /> 
- [x] T038 [P] [US1] Add <.dm_input field={@form[:organization]} label="Organization (O)" />
- [x] T039 [P] [US1] Add <.dm_input field={@form[:organizational_unit]} label="Organizational Unit (OU)" />
- [x] T040 [P] [US1] Add <.dm_input field={@form[:country]} label="Country (C)" maxlength="2" placeholder="US" />
- [x] T041 [P] [US1] Add <.dm_input field={@form[:state]} label="State/Province (ST)" />
- [x] T042 [P] [US1] Add <.dm_input field={@form[:locality]} label="Locality (L)" />
- [x] T043 [US1] Add <.dm_button type="submit" color="primary">Create CA</.dm_button>
- [x] T044 [US1] Apply TailwindCSS grid layout (grid grid-cols-2 gap-4) for subject fields
- [x] T045 [US1] Manual test: Navigate to /pki/ca/new, fill form, verify CA creation

### PKI Context Integration

- [x] T046 [US1] Extend PKIContext.initialize_ca/2 in apps/gsmlg_admin_web/lib/gsmlg/admin_web/contexts/pki_context.ex to accept subject_dn string
- [x] T047 [US1] Update CA.initialize/2 in apps/gsmlg/lib/gsmlg/pki/ca.ex to use KeyGenerator module
- [x] T048 [US1] Store key_type and key_algorithm_details in CA record
- [x] T049 [US1] Verify backward compatibility with existing CA creation code

**US1 Completion Criteria**: ✅ Admin can create CA with individual subject inputs, validation works, CA appears in list

---

## Phase 3: User Story 2 - Configure Key Type and Size (P2)

**Story Goal**: Administrator can select key type (RSA/ECDSA/Ed25519) with dynamic key size options.

**Independent Test**: Select each key type, verify correct key size options appear, create CA with each algorithm, verify key matches selection.

**Dependencies**: Requires Phase 2 (User Story 1) for basic form structure.

### Form Validation - Key Type Support (TDD)

- [x] T050 [US2] Add key_type and key_size fields to CAFormData in apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/pki_live/ca_live/form_data.ex
- [x] T051 [US2] Write tests for key_type/key_size validation in apps/gsmlg_admin_web/test/gsmlg/admin_web/live/pki_live/ca_live/form_data_test.exs
- [x] T052 [P] [US2] Implement validate_key_size/1 custom validator
- [x] T053 [P] [US2] Test RSA key sizes: 2048, 3072, 4096, 8192
- [x] T054 [P] [US2] Test ECDSA key sizes: 256, 384, 521
- [x] T055 [P] [US2] Test Ed25519 fixed size: 256
- [x] T056 [US2] Test invalid key size combinations (e.g., RSA 256, ECDSA 8192)
- [x] T057 [US2] Run key_type validation tests and verify all pass

### LiveView - Dynamic Key Size Selection (TDD)

- [x] T058 [US2] Write LiveView tests for key type changes in apps/gsmlg_admin_web/test/gsmlg/admin_web/live/pki_live/ca_live/index_test.exs
- [x] T059 [US2] Test: Selecting RSA shows key sizes 2048, 3072, 4096, 8192
- [x] T060 [US2] Test: Selecting ECDSA shows key sizes 256, 384, 521
- [x] T061 [US2] Test: Selecting Ed25519 hides key size selector
- [x] T062 [US2] Test: Changing key type updates default key size appropriately
- [x] T063 [US2] Implement handle_event("key_type_changed") in apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/pki_live/ca_live/index.ex
- [x] T064 [US2] Add assigns: key_type, available_key_sizes
- [x] T065 [US2] Implement PKIContext.get_key_size_options/1 helper in apps/gsmlg_admin_web/lib/gsmlg/admin_web/contexts/pki_context.ex
- [x] T066 [US2] Update form changeset when key type changes
- [x] T067 [US2] Run key type change tests and verify all pass

### Template - Key Type UI

- [x] T068 [US2] Add key type selector to form template in apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/pki_live/ca_live/index.html.heex
- [x] T069 [US2] Add <.dm_select field={@form[:key_type]} label="Key Type" phx-change="key_type_changed" options={[{"RSA", "rsa"}, {"ECDSA", "ecdsa"}, {"Ed25519", "ed25519"}]} />
- [x] T070 [US2] Add conditional <.dm_select field={@form[:key_size]} label="Key Size (bits)" options={...} /> (hidden for Ed25519)
- [x] T071 [US2] Add <%= if @key_type != "ed25519" do %> guard around key size selector
- [x] T072 [US2] Manual test: Change key types, verify size options update correctly

### PKI Integration - Algorithm Support

- [x] T073 [US2] Update CA.initialize/2 to accept :key_type and :key_size opts in apps/gsmlg/lib/gsmlg/pki/ca.ex
- [x] T074 [US2] Call KeyGenerator.generate_key with selected algorithm and size
- [x] T075 [US2] Store algorithm details in key_algorithm_details JSONB field (curve name for ECDSA, modulus for RSA)
- [x] T076 [US2] Write integration tests for CA creation with each key type in apps/gsmlg/test/gsmlg/pki/ca_test.exs
- [x] T077 [US2] Test RSA 4096, ECDSA P-384, Ed25519 CA creation
- [x] T078 [US2] Verify created CAs have correct key_type and key_algorithm_details
- [x] T079 [US2] Run integration tests and verify all pass

**US2 Completion Criteria**: ✅ Admin can select any key type, size options update dynamically, CAs created with correct algorithms

---

## Phase 4: User Story 3 - Set Custom Validity Period (P2)

**Story Goal**: Administrator can specify exact validity period using datetime range selector.

**Independent Test**: Use datetime picker to select start/end dates, submit form, verify CA validity matches selected dates exactly.

**Dependencies**: Requires Phase 2 (User Story 1) for basic form structure.

### DateTime Range Picker Component (TDD)

- [x] T080 [US3] Create DateTimeRangePicker component in apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/pki_live/components/datetime_range_picker.ex
- [x] T081 [US3] Write component tests in apps/gsmlg_admin_web/test/gsmlg/admin_web/live/pki_live/components/datetime_range_picker_test.exs
- [x] T082 [P] [US3] Add attr :start_field and :end_field
- [x] T083 [P] [US3] Implement HTML5 datetime-local inputs for start and end
- [x] T084 [US3] Style with TailwindCSS to match phoenix_duskmoon theme
- [x] T085 [US3] Add validation feedback for invalid ranges (end before start)
- [x] T086 [US3] Calculate default values: start = now, end = now + 10 years
- [x] T087 [US3] Run component tests and verify all pass

### Form Validation - Validity Period (TDD)

- [x] T088 [US3] Add validity_start and validity_end fields to CAFormData in apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/pki_live/ca_live/form_data.ex
- [x] T089 [US3] Write tests for datetime range validation in apps/gsmlg_admin_web/test/gsmlg/admin_web/live/pki_live/ca_live/form_data_test.exs
- [x] T090 [P] [US3] Implement validate_datetime_range/1 custom validator
- [x] T091 [P] [US3] Test: End date must be after start date
- [x] T092 [P] [US3] Test: Warning for periods > 20 years (7300 days)
- [x] T093 [P] [US3] Test: Default 10-year period pre-filled
- [x] T094 [US3] Run datetime validation tests and verify all pass

### LiveView - Validity Period Integration

- [x] T095 [US3] Write LiveView tests for datetime selection in apps/gsmlg_admin_web/test/gsmlg/admin_web/live/pki_live/ca_live/index_test.exs
- [x] T096 [US3] Test: Form renders with datetime range picker
- [x] T097 [US3] Test: Validation error appears for end < start
- [x] T098 [US3] Test: Warning appears for period > 20 years
- [x] T099 [US3] Test: CA created with exact validity dates from picker
- [x] T100 [US3] Update apply_action :new to set default validity dates in apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/pki_live/ca_live/index.ex
- [x] T101 [US3] Add validity_start/validity_end to form assigns
- [x] T102 [US3] Update handle_event("create_ca") to pass validity opts to PKIContext
- [x] T103 [US3] Run datetime LiveView tests and verify all pass

### Template - Validity Period UI

- [x] T104 [US3] Add datetime range picker to form template in apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/pki_live/ca_live/index.html.heex
- [x] T105 [US3] Add <.datetime_range_picker id="validity" start_field={@form[:validity_start]} end_field={@form[:validity_end]} />
- [x] T106 [US3] Add warning message display for long validity periods
- [x] T107 [US3] Manual test: Select various date ranges, verify validation and CA creation

### PKI Integration - Validity Dates

- [x] T108 [US3] Update CA.initialize/2 to accept :validity_start and :validity_end opts in apps/gsmlg/lib/gsmlg/pki/ca.ex
- [x] T109 [US3] Store dates in not_before and not_after fields (UTC)
- [x] T110 [US3] Write tests for validity period storage in apps/gsmlg/test/gsmlg/pki/ca_test.exs
- [x] T111 [US3] Verify timezone conversion (user input → UTC storage)
- [x] T112 [US3] Run validity period tests and verify all pass

**US3 Completion Criteria**: ✅ Admin can select exact validity period, validation prevents invalid ranges, CA created with correct dates

---

## Phase 5: User Story 4 - Encrypt Private Key (P3)

**Story Goal**: Administrator can optionally encrypt CA private key with password.

**Independent Test**: Enable encryption, provide password, create CA, verify private key PEM is encrypted and requires password for future use.

**Dependencies**: Requires Phase 2 (User Story 1) for basic CA creation.

### Form Validation - Password (TDD)

- [x] T113 [US4] Add encrypt_key, password, password_confirmation fields to CAFormData in apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/pki_live/ca_live/form_data.ex
- [x] T114 [US4] Write tests for password validation in apps/gsmlg_admin_web/test/gsmlg/admin_web/live/pki_live/ca_live/form_data_test.exs
- [x] T115 [P] [US4] Implement validate_password_if_encrypted/1 custom validator
- [x] T116 [P] [US4] Test: Password required if encrypt_key = true
- [x] T117 [P] [US4] Test: Password minimum 12 characters
- [x] T118 [P] [US4] Test: Password and confirmation must match
- [x] T119 [P] [US4] Test: Warning for weak passwords
- [x] T120 [US4] Run password validation tests and verify all pass

### LiveView - Encryption Toggle (TDD)

- [x] T121 [US4] Write LiveView tests for encryption option in apps/gsmlg_admin_web/test/gsmlg/admin_web/live/pki_live/ca_live/index_test.exs
- [x] T122 [US4] Test: Password fields appear when encrypt_key checked
- [x] T123 [US4] Test: Password fields hidden when encrypt_key unchecked
- [x] T124 [US4] Test: Validation error for mismatched passwords
- [x] T125 [US4] Test: CA created with encrypted private key
- [x] T126 [US4] Update handle_event("create_ca") to pass password opt in apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/pki_live/ca_live/index.ex
- [x] T127 [US4] Clear password from assigns immediately after CA creation
- [x] T128 [US4] Run encryption LiveView tests and verify all pass

### Template - Encryption UI

- [x] T129 [US4] Add encryption option to form template in apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/pki_live/ca_live/index.html.heex
- [x] T130 [US4] Add <.dm_checkbox field={@form[:encrypt_key]} label="Encrypt private key with password" />
- [x] T131 [US4] Add conditional password fields: <%= if Ecto.Changeset.get_field(@changeset, :encrypt_key) do %>
- [x] T132 [P] [US4] Add <.dm_input field={@form[:password]} type="password" label="Password" required />
- [x] T133 [P] [US4] Add <.dm_input field={@form[:password_confirmation]} type="password" label="Confirm Password" required />
- [x] T134 [US4] Add help text: "Password must be at least 12 characters. It will NOT be stored."
- [x] T135 [US4] Manual test: Toggle encryption, verify password fields show/hide

### PKI Integration - Key Encryption

- [x] T136 [US4] Update CA.initialize/2 to accept :encrypt_key and :password opts in apps/gsmlg/lib/gsmlg/pki/ca.ex
- [x] T137 [US4] Call KeyGenerator.encrypt_key/2 when encryption enabled
- [x] T138 [US4] Store encrypted PEM with "BEGIN ENCRYPTED PRIVATE KEY" header
- [x] T139 [US4] Set private_key_encrypted flag to true in CA record
- [x] T140 [US4] Write tests for encrypted key storage in apps/gsmlg/test/gsmlg/pki/key_generator_test.exs
- [x] T141 [US4] Test: Encrypted key cannot be used without password
- [x] T142 [US4] Test: Decryption with correct password succeeds
- [x] T143 [US4] Run encryption tests and verify all pass

**US4 Completion Criteria**: ✅ Admin can optionally encrypt private key, password validation works, encrypted keys require password for use

---

## Phase 6: Polish & Cross-Cutting Concerns

**Goal**: Final integration, comprehensive testing, and production readiness.

**Duration**: ~1.5 hours

### Integration Testing

- [ ] T144 [P] Write end-to-end test: Create CA with all features (RSA, custom validity, encryption) in apps/gsmlg_admin_web/test/gsmlg/admin_web/live/pki_live/ca_live/integration_test.exs
- [ ] T145 [P] Write end-to-end test: Create CA with ECDSA, no encryption
- [ ] T146 [P] Write end-to-end test: Create CA with Ed25519, minimal subject info
- [ ] T147 Run full test suite with `mix test` and verify all pass
- [ ] T148 Check test coverage with `mix test --cover` and ensure > 80%

### UI Polish

- [x] T149 [P] Add loading spinner during CA creation in apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/pki_live/ca_live/index.html.heex
- [x] T150 [P] Add confirmation dialog: "CA created successfully. Serial: #{serial}"
- [x] T151 [P] Improve error messages for common failure scenarios
- [x] T152 [P] Add help tooltips for PKI terms (key types, validity period, DN fields)
- [x] T153 Verify consistent phoenix_duskmoon styling across all form fields

### Performance Optimization

- [ ] T154 Measure form render time and verify < 300ms
- [ ] T155 Measure validation feedback time and verify < 300ms from field blur
- [ ] T156 Measure CA creation time (RSA 4096) and verify < 3 seconds
- [x] T157 Add telemetry events for CA creation metrics

### Documentation

- [x] T158 Update CA creation user documentation with new form fields
- [x] T159 Document password requirements and encryption behavior
- [ ] T160 Add code comments for complex validation logic
- [ ] T161 Update CHANGELOG.md with feature description

### Manual QA Checklist

- [ ] T162 Test on Firefox, Chrome, Safari for datetime picker compatibility
- [ ] T163 Test keyboard navigation (tab order, Enter to submit)
- [ ] T164 Test screen reader compatibility for validation errors
- [ ] T165 Test with slow network (form state persistence)
- [ ] T166 Test concurrent CA creation by multiple admins
- [ ] T167 Verify CA appears correctly in /pki/ca list with new fields

---

## Dependencies & Parallel Execution

### User Story Completion Order

```
Phase 1 (Setup) → Phase 2 (US1) → Phase 3 (US2)
                                 ↘ Phase 4 (US3)
                                 ↘ Phase 5 (US4)
```

**Critical Path**: Phase 1 → Phase 2 (US1) is blocking. All other stories depend on US1.

**Parallel Opportunities**: US2, US3, US4 can be implemented independently after US1 completes.

### Parallelizable Tasks (marked with [P])

**Within Phase 1**:
- T010-T012: Key generation for different algorithms (independent)
- T005-T007: Schema field additions (independent)

**Within Phase 2 (US1)**:
- T017-T020: Form field validations (independent)
- T037-T042: Template input components (independent)

**Within Phase 3 (US2)**:
- T053-T055: Key size validation tests (independent)

**Within Phase 4 (US3)**:
- T082-T083: DateTimePicker attributes (independent)
- T090-T093: Datetime validation tests (independent)

**Within Phase 5 (US4)**:
- T116-T119: Password validation tests (independent)
- T132-T133: Password input fields (independent)

**Phase 6 (Polish)**:
- T144-T146: End-to-end tests (independent)
- T149-T152: UI polish items (independent)

### Example Parallel Execution Commands

**After US1 Complete**, run in parallel:
```bash
# Terminal 1: Implement US2 (Key types)
mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/live/pki_live/ca_live/form_data_test.exs --only us2

# Terminal 2: Implement US3 (Validity period)
mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/live/pki_live/ca_live/form_data_test.exs --only us3

# Terminal 3: Implement US4 (Encryption)
mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/live/pki_live/ca_live/form_data_test.exs --only us4
```

---

## MVP Definition

**Minimum Viable Product**: Phase 2 (User Story 1) only

**Deliverable**: Admin can create CA with individual subject field inputs using phoenix_duskmoon components. Basic RSA key generation with default parameters.

**Testing**: US1 independently testable and verifiable.

**Incremental Delivery**:
- **Release 1**: US1 (P1) - Core CA creation with subject fields
- **Release 2**: US1 + US2 (P2) - Add key type/size selection
- **Release 3**: US1 + US2 + US3 (P2) - Add custom validity periods
- **Release 4**: All stories (P1-P3) - Add encryption option

---

## Task Summary

**Total Tasks**: 167
**Test Tasks**: 45 (TDD approach)
**Implementation Tasks**: 122

**Tasks by User Story**:
- Phase 1 (Setup): 14 tasks
- Phase 2 (US1 - P1): 35 tasks (19 implementation + 16 tests)
- Phase 3 (US2 - P2): 30 tasks (18 implementation + 12 tests)
- Phase 4 (US3 - P2): 33 tasks (22 implementation + 11 tests)
- Phase 5 (US4 - P3): 31 tasks (25 implementation + 6 tests)
- Phase 6 (Polish): 24 tasks (integration + QA)

**Parallel Opportunities**: 47 tasks marked with [P] can run concurrently

**Estimated Duration**: ~11 hours (based on quickstart.md estimates)
- Phase 1: 1.5 hours
- Phase 2 (US1): 3 hours
- Phase 3 (US2): 2 hours
- Phase 4 (US3): 2 hours
- Phase 5 (US4): 1.5 hours
- Phase 6 (Polish): 1 hour

**Format Validation**: ✅ All 167 tasks follow checklist format with IDs, labels, and file paths

---

## Next Steps

1. **Review tasks** and adjust priorities if needed
2. **Start with Phase 1** (Setup) to establish foundation
3. **Complete US1 (Phase 2)** as MVP milestone
4. **Test US1 independently** before moving to US2/US3/US4
5. **Implement US2-US4** in parallel (3 developers) or sequentially (1 developer)
6. **Run Phase 6 polish** for production readiness

**Development Command**: `mix test --stale` to run only tests affected by code changes during development.
