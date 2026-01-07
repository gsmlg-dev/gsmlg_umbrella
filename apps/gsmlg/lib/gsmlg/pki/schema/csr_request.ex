defmodule GSMLG.PKI.Schema.CSRRequest do
  @moduledoc """
  Schema for managing Certificate Signing Request (CSR) approval workflow.

  This table stores CSRs that are pending approval before being issued as certificates.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias GSMLG.PKI.CSR

  # Suppress undefined module warnings for PKI modules not yet implemented
  @compile {:no_warn_undefined, [GSMLG.PKI.CSR, GSMLG.PKI.RDNSequence]}

  schema "pki_csr_requests" do
    field :csr_pem, :string
    field :subject, :string
    field :requested_by, :string
    field :status, Ecto.Enum, values: [:pending, :approved, :rejected, :issued]
    field :ca_id, :string
    field :template, Ecto.Enum, values: [:server, :client, :ca, :code_signing, :email]
    field :validity_days, :integer, default: 365
    field :notes, :string
    field :certificate_serial, :integer

    timestamps()
  end

  @doc false
  def changeset(csr_request, attrs) do
    csr_request
    |> cast(attrs, [
      :csr_pem,
      :subject,
      :requested_by,
      :status,
      :ca_id,
      :template,
      :validity_days,
      :notes,
      :certificate_serial
    ])
    |> validate_required([:csr_pem, :subject, :requested_by, :ca_id])
    |> validate_number(:validity_days, greater_than: 0, less_than_or_equal_to: 7300)
    |> validate_csr()
  end

  defp validate_csr(changeset) do
    case get_change(changeset, :csr_pem) do
      nil ->
        changeset

      pem ->
        case CSR.from_pem(pem) do
          {:ok, csr} ->
            # Extract subject from CSR
            {:ok, subject} = CSR.subject(csr)
            subject_str = GSMLG.PKI.RDNSequence.to_string(subject)
            put_change(changeset, :subject, subject_str)

          {:error, _} ->
            add_error(changeset, :csr_pem, "invalid CSR format")
        end
    end
  end
end
