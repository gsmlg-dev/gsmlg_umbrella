# Feature Specification: Enhanced PKI CA Creation Form

**Feature Branch**: `001-enhance-pki-ca-form`
**Created**: 2025-11-18
**Status**: Draft
**Input**: User description: "Enhance the page /pki/ca/new create ca should use more phoenix_duskmoon form. It should includes all the CA fields, each fields should have their own input, the validity days should be a datetime range selector that can select a range of date time to the CA. Key size should includes 2048, 3072, 4096 and 8192. There should support more key type. The CA should support encrypt private key."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Create Basic Root CA (Priority: P1)

An administrator needs to create a new root Certificate Authority with complete subject information using individual, clearly labeled form fields.

**Why this priority**: This is the core functionality - creating a CA is the foundational requirement that all other features depend on. Without this, the PKI system cannot function.

**Independent Test**: Can be fully tested by filling out all required subject fields (Common Name, Organization, Country, etc.) using separate input components and successfully creating a CA. Delivers a functioning root CA that can be used to issue certificates.

**Acceptance Scenarios**:

1. **Given** an administrator is on the CA creation page, **When** they fill in all required subject fields (CN, O, OU, C, ST, L) in separate input fields, **Then** each field is validated independently and shows appropriate validation feedback
2. **Given** an administrator has filled all required fields, **When** they submit the form, **Then** a new CA is created and the administrator is redirected to the CA details page
3. **Given** an administrator is filling the form, **When** they leave a required field empty, **Then** the field shows a validation error and the form cannot be submitted

---

### User Story 2 - Configure Key Type and Size (Priority: P2)

An administrator needs to select the cryptographic key type (RSA, ECDSA, Ed25519) and appropriate key size for their security requirements.

**Why this priority**: Different use cases require different cryptographic algorithms. Modern PKI systems need flexibility to support various key types beyond just RSA, and different key sizes for balancing security and performance.

**Independent Test**: Can be tested by selecting different key types from a dropdown and verifying that appropriate key size options appear (RSA: 2048/3072/4096/8192, ECDSA: 256/384/521, Ed25519: fixed). Delivers a CA with the specified cryptographic parameters.

**Acceptance Scenarios**:

1. **Given** an administrator is creating a CA, **When** they select "RSA" as the key type, **Then** key size options of 2048, 3072, 4096, and 8192 bits are available
2. **Given** an administrator is creating a CA, **When** they select "ECDSA" as the key type, **Then** key size options of 256, 384, and 521 bits are available
3. **Given** an administrator is creating a CA, **When** they select "Ed25519" as the key type, **Then** no key size selection is needed (fixed at 256 bits)
4. **Given** an administrator changes the key type, **When** the previously selected key size is not available for the new type, **Then** the form automatically selects a default appropriate size

---

### User Story 3 - Set Custom Validity Period (Priority: P2)

An administrator needs to specify the exact validity period for the CA certificate using a date/time range selector to meet organizational policy requirements.

**Why this priority**: Different organizations have different certificate validity policies. Some require short-lived CAs (1 year) while others use long-lived CAs (10-20 years). A flexible date range selector allows precise control.

**Independent Test**: Can be tested by using the datetime range selector to pick start and end dates, validating that the CA is created with exactly those validity dates. Delivers a CA with custom lifetime that matches organizational requirements.

**Acceptance Scenarios**:

1. **Given** an administrator is creating a CA, **When** they open the validity period selector, **Then** they see a datetime range picker with start and end date/time fields
2. **Given** an administrator selects a validity period, **When** the end date is before the start date, **Then** a validation error appears and the form cannot be submitted
3. **Given** an administrator selects a validity period, **When** the period exceeds reasonable limits (e.g., more than 30 years), **Then** a warning message appears
4. **Given** an administrator has not selected a validity period, **When** they view the form, **Then** a default period (e.g., 10 years from now) is pre-filled

---

### User Story 4 - Encrypt Private Key (Priority: P3)

An administrator needs to protect the CA's private key with a password to prevent unauthorized use if the key file is compromised.

**Why this priority**: While important for security, this is an optional feature that doesn't block basic CA creation. However, for production CAs, encrypted private keys are a security best practice.

**Independent Test**: Can be tested by enabling private key encryption, providing a password, creating the CA, and verifying that the private key cannot be used without the correct password. Delivers enhanced security for sensitive CA private keys.

**Acceptance Scenarios**:

1. **Given** an administrator is creating a CA, **When** they enable "Encrypt Private Key" option, **Then** password and password confirmation fields appear
2. **Given** an administrator has enabled encryption, **When** they provide mismatched passwords, **Then** a validation error appears
3. **Given** an administrator has enabled encryption, **When** they provide a weak password (< 12 characters), **Then** a warning appears suggesting a stronger password
4. **Given** an administrator has enabled encryption with a valid password, **When** the CA is created, **Then** the private key is encrypted and requires the password for future operations

---

### Edge Cases

- What happens when an administrator tries to create a CA with a Common Name that already exists in the system?
- How does the system handle extremely long validity periods (e.g., 100 years)?
- What validation occurs when special characters or non-ASCII characters are entered in subject fields?
- How does the form behave when an administrator navigates away with unsaved changes?
- What happens if private key encryption is enabled but no password is provided?
- How does the system handle timezone differences when displaying/storing validity dates?

## Clarifications

### Session 2025-11-18

- Q: At what point should the system warn administrators that they're creating a CA with an unusually long validity period? → A: 20 years (industry standard for root CAs; balances security with operational convenience)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST provide separate, clearly labeled input fields for all X.509 subject components (Common Name, Organization, Organizational Unit, Country, State/Province, Locality)
- **FR-002**: System MUST use phoenix_duskmoon form components for all form inputs to maintain consistent UI/UX
- **FR-003**: System MUST provide a key type selector with options for at least RSA, ECDSA, and Ed25519 algorithms
- **FR-004**: System MUST provide key size options of 2048, 3072, 4096, and 8192 bits when RSA is selected
- **FR-005**: System MUST provide key size options of 256, 384, and 521 bits when ECDSA is selected
- **FR-006**: System MUST fix key size at 256 bits when Ed25519 is selected (no user selection needed)
- **FR-007**: System MUST provide a datetime range selector component for specifying CA certificate validity period with both start and end dates/times
- **FR-008**: System MUST validate that the validity end date/time is after the start date/time
- **FR-009**: System MUST provide an optional checkbox to enable private key encryption
- **FR-010**: System MUST display password and confirmation fields when private key encryption is enabled
- **FR-011**: System MUST validate that password and confirmation fields match when encryption is enabled
- **FR-012**: System MUST validate all required fields before allowing form submission
- **FR-013**: System MUST show field-level validation errors immediately after a user leaves an invalid field
- **FR-014**: System MUST prevent form submission if any validation errors exist
- **FR-015**: System MUST provide clear, actionable error messages for each validation failure
- **FR-016**: System MUST pre-fill the validity period with a reasonable default (e.g., current date as start, 10 years as duration)
- **FR-017**: System MUST display a confirmation summary before creating the CA showing all selected options
- **FR-018**: System MUST warn users when selecting validity periods longer than 20 years

### Key Entities *(include if feature involves data)*

- **Certificate Authority (CA)**: Represents a PKI certificate authority with attributes including subject information (CN, O, OU, C, ST, L), key type, key size, validity period (start and end dates), and optional private key encryption status
- **Subject Information**: Collection of X.509 distinguished name components that identify the CA, including Common Name (mandatory), Organization, Organizational Unit, Country code (2-letter ISO), State/Province, and Locality
- **Cryptographic Key**: The public/private key pair for the CA, characterized by algorithm type (RSA/ECDSA/Ed25519) and size in bits, optionally encrypted with a user-provided password
- **Validity Period**: Time range during which the CA certificate is valid, defined by start datetime and end datetime in ISO 8601 format

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Administrators can successfully create a CA with all required fields in under 3 minutes
- **SC-002**: Form validation catches 100% of invalid inputs before submission (no server-side rejections for client-validatable errors)
- **SC-003**: All form fields use consistent phoenix_duskmoon components matching the existing admin UI style
- **SC-004**: Administrators can successfully create CAs with each supported key type (RSA, ECDSA, Ed25519) and verify the created CA matches the selected parameters
- **SC-005**: Datetime range selector prevents selection of invalid date ranges (end before start) 100% of the time
- **SC-006**: Private key encryption, when enabled, successfully protects the key and requires the correct password for all future operations
- **SC-007**: Form auto-save or unsaved changes warning prevents accidental data loss when navigating away
- **SC-008**: Field-level validation feedback appears within 300ms of user leaving an invalid field

## Assumptions

- The phoenix_duskmoon component library includes or can be extended with a datetime range selector component
- The backend PKI system supports all three key types (RSA, ECDSA, Ed25519) with the specified key sizes
- Administrators using this form have basic understanding of PKI concepts (CA, key types, validity periods)
- The system uses UTC for all datetime storage and handles timezone conversion for display
- Password strength requirements for private key encryption follow industry standard recommendations (minimum 12 characters)
- The maximum recommended validity period for CAs is 20 years (industry standard for root CAs)
- Form state persistence (auto-save or session storage) is handled by existing phoenix_duskmoon form infrastructure
