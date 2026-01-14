defmodule GSMLG.PKI.Schema.CertificateAuthority do
  @moduledoc """
  Ecto schema for Certificate Authority entities.

  Stores CA certificates with their private keys, metadata, and cryptographic parameters.
  Supports multiple key types (RSA, ECDSA, Ed25519) and optional private key encryption.

  ## Fields

  - `id` - Unique CA identifier (format: "ca:uuid")
  - `subject` - X.509 Distinguished Name (e.g., "/CN=Example CA/O=Example Corp/C=US")
  - `serial` - Certificate serial number (hex-encoded)
  - `status` - Current status: "active", "revoked", "expired"
  - `certificate_pem` - CA certificate in PEM format
  - `private_key_pem` - CA private key in PEM format (may be encrypted)
  - `public_key_pem` - CA public key in PEM format
  - `key_type` - Key algorithm: "rsa", "ecdsa", "ed25519"
  - `key_algorithm_details` - Algorithm-specific metadata (JSONB)
  - `private_key_encrypted` - Whether private_key_pem is encrypted
  - `not_before` - Certificate validity start (UTC)
  - `not_after` - Certificate validity end (UTC)
  - `ski` - Subject Key Identifier (hex-encoded)
  - `current_sequence` - Event sequence counter for this CA

  ## Key Algorithm Details Structure

  ### RSA
  ```json
  {
    "modulus_bits": 4096,
    "public_exponent": 65537
  }
  ```

  ### ECDSA
  ```json
  {
    "curve_name": "secp384r1",
    "key_size_bits": 384
  }
  ```

  ### Ed25519
  ```json
  {
    "curve": "ed25519",
    "key_size_bits": 256
  }
  ```
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "certificate_authorities" do
    field :subject, :string
    field :serial, :string
    field :status, :string, default: "active"

    # Certificate data
    field :certificate_pem, :string
    field :private_key_pem, :string
    field :public_key_pem, :string

    # Key configuration
    field :key_type, :string, default: "rsa"
    field :key_algorithm_details, :map
    field :private_key_encrypted, :boolean, default: false

    # Validity period
    field :not_before, :utc_datetime_usec
    field :not_after, :utc_datetime_usec

    # Metadata
    field :ski, :string
    field :current_sequence, :integer, default: 0

    timestamps()
  end

  @doc """
  Creates a changeset for a new Certificate Authority.

  ## Required Fields

  - `id` - Unique CA identifier
  - `subject` - X.509 Distinguished Name
  - `serial` - Certificate serial number
  - `certificate_pem` - CA certificate in PEM format
  - `private_key_pem` - CA private key in PEM format
  - `public_key_pem` - CA public key in PEM format
  - `not_before` - Validity start timestamp
  - `not_after` - Validity end timestamp

  ## Optional Fields

  - `status` - Defaults to "active"
  - `key_type` - Defaults to "rsa"
  - `key_algorithm_details` - Algorithm-specific metadata
  - `private_key_encrypted` - Defaults to false
  - `ski` - Subject Key Identifier
  - `current_sequence` - Defaults to 0
  """
  def changeset(ca, attrs) do
    ca
    |> cast(attrs, [
      :id,
      :subject,
      :serial,
      :status,
      :certificate_pem,
      :private_key_pem,
      :public_key_pem,
      :key_type,
      :key_algorithm_details,
      :private_key_encrypted,
      :not_before,
      :not_after,
      :ski,
      :current_sequence
    ])
    |> validate_required([
      :id,
      :subject,
      :serial,
      :certificate_pem,
      :private_key_pem,
      :public_key_pem,
      :not_before,
      :not_after
    ])
    |> validate_inclusion(:status, ["active", "revoked", "expired"])
    |> validate_inclusion(:key_type, ["rsa", "ecdsa", "ed25519"])
    |> validate_key_algorithm_details()
    |> validate_validity_period()
    |> unique_constraint(:serial, name: :certificate_authorities_serial_unique)
    |> unique_constraint(:subject, name: :certificate_authorities_subject_unique)
  end

  # Validates that key_algorithm_details contains appropriate fields for the key_type.
  defp validate_key_algorithm_details(changeset) do
    key_type = get_field(changeset, :key_type)
    details = get_field(changeset, :key_algorithm_details)

    case {key_type, details} do
      {"rsa", %{"modulus_bits" => bits}} when is_integer(bits) and bits >= 2048 ->
        changeset

      {"ecdsa", %{"curve_name" => curve, "key_size_bits" => bits}}
      when is_binary(curve) and is_integer(bits) ->
        changeset

      {"ed25519", %{"curve" => "ed25519", "key_size_bits" => 256}} ->
        changeset

      {_, nil} ->
        changeset

      {key_type, _} ->
        add_error(
          changeset,
          :key_algorithm_details,
          "invalid structure for key_type #{key_type}"
        )
    end
  end

  # Validates that not_after is after not_before.
  defp validate_validity_period(changeset) do
    not_before = get_field(changeset, :not_before)
    not_after = get_field(changeset, :not_after)

    if not_before && not_after && DateTime.compare(not_after, not_before) != :gt do
      add_error(changeset, :not_after, "must be after not_before")
    else
      changeset
    end
  end

  @doc """
  Returns whether the CA is currently active (not revoked or expired).
  """
  def active?(%__MODULE__{status: "active", not_after: not_after}) do
    DateTime.compare(DateTime.utc_now(), not_after) == :lt
  end

  def active?(_ca), do: false

  @doc """
  Returns whether the CA certificate has expired.
  """
  def expired?(%__MODULE__{not_after: not_after}) do
    DateTime.compare(DateTime.utc_now(), not_after) != :lt
  end

  @doc """
  Increments the current sequence number for event sourcing.
  """
  def increment_sequence_changeset(ca) do
    change(ca, current_sequence: ca.current_sequence + 1)
  end
end
