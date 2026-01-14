defmodule GSMLG.AdminWeb.PKILive.CALive.FormData do
  @moduledoc """
  Embedded schema for CA creation form validation.

  Handles form input validation for the enhanced PKI CA creation page with
  individual X.509 subject fields, key type/size selection, datetime validity
  range, and optional private key encryption.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # X.509 Subject Components
    field(:common_name, :string)
    field(:organization, :string)
    field(:organizational_unit, :string)
    field(:country, :string)
    field(:state, :string)
    field(:locality, :string)

    # Key Configuration
    field(:key_type, :string, default: "rsa")
    field(:key_size, :integer, default: 4096)

    # Validity Period
    field(:validity_start, :utc_datetime)
    field(:validity_end, :utc_datetime)

    # Private Key Encryption
    field(:encrypt_key, :boolean, default: false)
    field(:password, :string, virtual: true)
    field(:password_confirmation, :string, virtual: true)
  end

  @doc """
  Creates a changeset for CA form data validation.

  ## Validation Rules

  ### Subject Fields
  - `common_name` - Required, min 1 char, max 64 chars
  - `organization` - Optional, max 64 chars
  - `organizational_unit` - Optional, max 64 chars
  - `country` - Optional, exactly 2 uppercase letters if provided
  - `state` - Optional, max 128 chars
  - `locality` - Optional, max 128 chars

  ### Key Configuration
  - `key_type` - Required, one of: "rsa", "ecdsa", "ed25519"
  - `key_size` - Required, valid for selected key_type

  ### Validity Period
  - `validity_start` - Required, must be DateTime
  - `validity_end` - Required, must be after validity_start

  ### Encryption (if encrypt_key is true)
  - `password` - Required, min 12 chars
  - `password_confirmation` - Required, must match password
  """
  def changeset(form_data, attrs) do
    form_data
    |> cast(attrs, [
      :common_name,
      :organization,
      :organizational_unit,
      :country,
      :state,
      :locality,
      :key_type,
      :key_size,
      :validity_start,
      :validity_end,
      :encrypt_key,
      :password,
      :password_confirmation
    ])
    |> validate_required([:common_name, :key_type, :key_size, :validity_start, :validity_end])
    |> validate_subject_fields()
    |> validate_key_configuration()
    |> validate_validity_period()
    |> validate_password_if_encrypted()
  end

  # Subject field validation

  defp validate_subject_fields(changeset) do
    changeset
    |> validate_length(:common_name, min: 1, max: 64)
    |> validate_length(:organization, max: 64)
    |> validate_length(:organizational_unit, max: 64)
    |> validate_country_code()
    |> validate_length(:state, max: 128)
    |> validate_length(:locality, max: 128)
  end

  # Validates ISO 3166-1 alpha-2 country code format.
  # Country is optional, but if provided must be exactly 2 uppercase letters.
  # Examples: US, GB, CN, DE, JP
  defp validate_country_code(changeset) do
    country = get_field(changeset, :country)

    cond do
      # Country is optional - empty or nil is valid
      is_nil(country) || country == "" ->
        changeset

      # Must be exactly 2 characters (ISO 3166-1 alpha-2 requirement)
      String.length(country) != 2 ->
        add_error(changeset, :country, "must be exactly 2 characters")

      # Must be uppercase to match X.509 DN conventions
      country != String.upcase(country) ->
        add_error(changeset, :country, "must be uppercase (e.g., US, GB, CN)")

      # Must contain only letters (A-Z), no digits or symbols
      not String.match?(country, ~r/^[A-Z]{2}$/) ->
        add_error(changeset, :country, "must contain only letters")

      true ->
        changeset
    end
  end

  # Key configuration validation

  defp validate_key_configuration(changeset) do
    changeset
    |> validate_inclusion(:key_type, ["rsa", "ecdsa", "ed25519"])
    |> validate_key_size_for_type()
  end

  # Validates key size is appropriate for the selected key type.
  # Different algorithms support different key sizes:
  # - RSA: 2048, 3072, 4096, 8192 bits (industry standards)
  # - ECDSA: 256 (P-256), 384 (P-384), 521 (P-521) bits (NIST curves)
  # - Ed25519: 256 bits only (fixed size, no alternatives)
  defp validate_key_size_for_type(changeset) do
    key_type = get_field(changeset, :key_type)
    key_size = get_field(changeset, :key_size)

    valid_sizes =
      case key_type do
        "rsa" -> [2048, 3072, 4096, 8192]
        "ecdsa" -> [256, 384, 521]
        "ed25519" -> [256]
        _ -> []
      end

    if key_size in valid_sizes do
      changeset
    else
      add_error(
        changeset,
        :key_size,
        "invalid key size #{key_size} for key type #{key_type}"
      )
    end
  end

  # Validity period validation

  defp validate_validity_period(changeset) do
    validity_start = get_field(changeset, :validity_start)
    validity_end = get_field(changeset, :validity_end)

    cond do
      is_nil(validity_start) || is_nil(validity_end) ->
        changeset

      DateTime.compare(validity_end, validity_start) != :gt ->
        add_error(changeset, :validity_end, "must be after validity start")

      true ->
        changeset
        |> maybe_warn_long_validity()
    end
  end

  # Warns if validity period exceeds industry best practice of 20 years.
  # Uses 365.25 days per year to account for leap years in duration calculation.
  # Industry standards (CA/Browser Forum, PCI DSS) recommend 10-20 year maximum
  # for root CAs to balance security (shorter is better) and operational stability.
  defp maybe_warn_long_validity(changeset) do
    validity_start = get_field(changeset, :validity_start)
    validity_end = get_field(changeset, :validity_end)

    # Calculate duration in years, accounting for leap years (365.25 days/year)
    years_diff = DateTime.diff(validity_end, validity_start, :day) / 365.25

    if years_diff > 20 do
      add_error(
        changeset,
        :validity_end,
        "validity period exceeds 20 years (#{Float.round(years_diff, 1)} years) - consider using a shorter period"
      )
    else
      changeset
    end
  end

  # Password validation (if encryption enabled)

  defp validate_password_if_encrypted(changeset) do
    encrypt_key = get_field(changeset, :encrypt_key)

    if encrypt_key do
      changeset
      |> validate_required([:password, :password_confirmation],
        message: "is required when encryption is enabled"
      )
      |> validate_length(:password, min: 12, message: "must be at least 12 characters")
      |> validate_password_strength()
      |> validate_confirmation(:password, message: "does not match password")
    else
      changeset
    end
  end

  # Validates password meets minimum complexity requirements for PKCS#8 encryption.
  # Requirements ensure password provides adequate entropy against brute-force attacks:
  # - At least one uppercase letter (26 possibilities)
  # - At least one lowercase letter (26 possibilities)
  # - At least one digit (10 possibilities)
  # Combined with 12+ character minimum, this provides ~62^12 possible combinations.
  defp validate_password_strength(changeset) do
    password = get_field(changeset, :password)

    if is_nil(password) || password == "" do
      changeset
    else
      # Check for basic password strength criteria
      has_uppercase = String.match?(password, ~r/[A-Z]/)
      has_lowercase = String.match?(password, ~r/[a-z]/)
      has_digit = String.match?(password, ~r/[0-9]/)

      if has_uppercase && has_lowercase && has_digit do
        changeset
      else
        add_error(
          changeset,
          :password,
          "must contain uppercase, lowercase, and digit characters"
        )
      end
    end
  end

  @doc """
  Builds an X.509 Distinguished Name string from form data.

  Returns a DN string in the format "/CN=.../O=.../OU=.../C=.../ST=.../L=..."
  with only non-empty fields included.

  ## Examples

      iex> form_data = %FormData{common_name: "Test CA", organization: "Test Org", country: "US"}
      iex> FormData.build_subject_dn(form_data)
      "/CN=Test CA/O=Test Org/C=US"
  """
  def build_subject_dn(%__MODULE__{} = form_data) do
    [
      {"CN", form_data.common_name},
      {"O", form_data.organization},
      {"OU", form_data.organizational_unit},
      {"C", form_data.country},
      {"ST", form_data.state},
      {"L", form_data.locality}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) || String.trim(v) == "" end)
    |> Enum.map(fn {k, v} -> "/#{k}=#{v}" end)
    |> Enum.join("")
  end
end
