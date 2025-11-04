defmodule GSMLG.PKI.Schema.Event do
  @moduledoc """
  Ecto schema for PKI event sourcing.

  Stores immutable events for all PKI operations including CA initialization,
  certificate issuance, revocation, renewal, and CRL generation.

  ## Event Types

  - `:ca_initialized` - A new Certificate Authority was created
  - `:certificate_issued` - A certificate was issued by a CA
  - `:certificate_revoked` - A certificate was revoked
  - `:certificate_renewed` - A certificate was renewed
  - `:crl_generated` - A Certificate Revocation List was generated
  - `:certificate_validated` - A certificate chain validation was performed

  ## Metadata Structure

  The `metadata` field is a JSONB column containing event-specific data:

  ### CA Initialized
  - ca_id, subject, key_type, key_size, curve, validity_days
  - certificate_der, public_key_der, ski, serial
  - not_before, not_after, hash

  ### Certificate Issued
  - serial, subject, issuer_ca_id, issuer_subject
  - certificate_type, template, key_type, key_info
  - validity_days, not_before, not_after, certificate_der
  - subject_alternative_names, ski, aki, csr_fingerprint, auto_renew

  ### Certificate Revoked
  - serial, ca_id, reason, revocation_date, invalidity_date
  - subject, issuer_subject

  ### CRL Generated
  - ca_id, crl_number, this_update, next_update
  - revoked_count, crl_der, crl_size_bytes
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "pki_events" do
    field :event_type, Ecto.Enum,
      values: [
        :ca_initialized,
        :certificate_issued,
        :certificate_revoked,
        :certificate_renewed,
        :crl_generated,
        :certificate_validated
      ]

    field :timestamp, :utc_datetime_usec
    field :sequence, :integer
    field :ca_id, :string
    field :metadata, :map
    field :actor, :string
    field :correlation_id, :string
    field :inserted_at, :utc_datetime_usec, default: nil
  end

  @doc """
  Creates a changeset for a new PKI event.

  ## Parameters

  - `event` - The event struct (usually %__MODULE__{})
  - `attrs` - Map of attributes to set

  ## Required Fields

  - `id` - Unique event identifier (usually "event:uuid")
  - `event_type` - Type of PKI event (atom)
  - `timestamp` - When the event occurred (UTC)
  - `sequence` - Sequence number within the CA (must be > 0)
  - `ca_id` - CA identifier (string)

  ## Optional Fields

  - `metadata` - Event-specific data (map/JSONB)
  - `actor` - Who performed the action (email/username)
  - `correlation_id` - Request tracking identifier
  """
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :id,
      :event_type,
      :timestamp,
      :sequence,
      :ca_id,
      :metadata,
      :actor,
      :correlation_id
    ])
    |> validate_required([:id, :event_type, :timestamp, :sequence, :ca_id])
    |> validate_number(:sequence, greater_than: 0)
    |> unique_constraint([:ca_id, :sequence], name: :pki_events_ca_sequence_unique)
  end

  @doc """
  Converts a PKI event from the Events module format to Ecto schema format.

  This is used when storing events that were created by the GSMLG.PKI library.
  """
  def from_pki_event(event) when is_map(event) do
    %__MODULE__{
      id: event.id,
      event_type: event.event_type,
      timestamp: event.timestamp,
      sequence: event.sequence,
      ca_id: event.ca_id,
      metadata: event.metadata || %{},
      actor: Map.get(event, :actor),
      correlation_id: Map.get(event, :correlation_id)
    }
  end

  @doc """
  Converts an Ecto PKI event back to the Events module format.

  This ensures compatibility with the existing GSMLG.PKI library code.
  """
  def to_pki_event(%__MODULE__{} = event) do
    %{
      id: event.id,
      type: :pki_event,
      event_type: event.event_type,
      timestamp: event.timestamp,
      sequence: event.sequence,
      ca_id: event.ca_id,
      metadata: event.metadata || %{},
      actor: event.actor,
      correlation_id: event.correlation_id
    }
  end
end
