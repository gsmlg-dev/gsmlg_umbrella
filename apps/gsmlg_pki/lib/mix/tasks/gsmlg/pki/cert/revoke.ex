defmodule Mix.Tasks.Gsmlg.Pki.Cert.Revoke do
  use Mix.Task

  @shortdoc "Revoke a certificate"

  @moduledoc """
  Revoke a previously issued certificate.

  ## Usage

      mix gsmlg.pki.cert.revoke [options]

  ## Options

      --ca-cert       - Path to CA certificate (required)
      --ca-key        - Path to CA private key (required)
      --serial        - Certificate serial number to revoke (required)
      --reason        - Revocation reason (default: unspecified)
      --actor         - Who is revoking the certificate (default: system)

  ## Revocation Reasons

      unspecified         - No specific reason
      keyCompromise       - Private key was compromised
      cACompromise        - CA was compromised
      affiliationChanged  - Subject affiliation changed
      superseded          - Certificate was replaced
      cessationOfOperation - Certificate no longer needed
      certificateHold     - Temporary revocation (reversible)
      privilegeWithdrawn  - Privileges were withdrawn
      aACompromise        - Attribute authority compromised

  ## Examples

      # Revoke certificate due to key compromise
      mix gsmlg.pki.cert.revoke \\
        --ca-cert ca/ca-cert.pem \\
        --ca-key ca/ca-key.pem \\
        --serial 12345 \\
        --reason keyCompromise

      # Revoke certificate (no specific reason)
      mix gsmlg.pki.cert.revoke \\
        --ca-cert ca/ca-cert.pem \\
        --ca-key ca/ca-key.pem \\
        --serial 67890

      # Revoke certificate due to replacement
      mix gsmlg.pki.cert.revoke \\
        --ca-cert ca/ca-cert.pem \\
        --ca-key ca/ca-key.pem \\
        --serial 11111 \\
        --reason superseded \\
        --actor "admin@example.com"

  ## Event Logging

  Certificate revocation is logged to PostgreSQL as an immutable event with:
  - Serial number
  - Revocation reason
  - Revocation timestamp
  - Actor (who revoked it)

  This enables:
  - Complete audit trail
  - Revocation checking during validation
  - CRL generation
  - Compliance reporting

  ## CRL Generation

  After revoking certificates, regenerate the CRL:

      mix gsmlg.pki.crl.generate \\
        --ca-cert ca/ca-cert.pem \\
        --ca-key ca/ca-key.pem \\
        --output ca.crl
  """

  alias GSMLG.PKI.{CA, Certificate, PrivateKey}

  @revocation_reasons %{
    "unspecified" => :unspecified,
    "keyCompromise" => :keyCompromise,
    "cACompromise" => :cACompromise,
    "affiliationChanged" => :affiliationChanged,
    "superseded" => :superseded,
    "cessationOfOperation" => :cessationOfOperation,
    "certificateHold" => :certificateHold,
    "privilegeWithdrawn" => :privilegeWithdrawn,
    "aACompromise" => :aACompromise
  }

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          ca_cert: :string,
          ca_key: :string,
          serial: :integer,
          reason: :string,
          actor: :string
        ]
      )

    # Validate required options
    ca_cert_path = Keyword.get(opts, :ca_cert) || missing_required("--ca-cert")
    ca_key_path = Keyword.get(opts, :ca_key) || missing_required("--ca-key")
    serial = Keyword.get(opts, :serial) || missing_required("--serial")

    # Parse options with defaults
    reason = parse_reason(Keyword.get(opts, :reason, "unspecified"))
    actor = Keyword.get(opts, :actor, "system")

    # Load CA certificate and key
    Mix.shell().info("Loading CA certificate and key...")

    ca_cert_pem = File.read!(ca_cert_path)
    ca_key_pem = File.read!(ca_key_path)

    {:ok, ca_cert} = Certificate.from_pem(ca_cert_pem)
    {:ok, ca_key} = PrivateKey.from_pem(ca_key_pem)

    # Extract CA info
    ca_subject = extract_subject(ca_cert)

    # Create CA structure
    ca = %{
      id: extract_ca_id(ca_cert),
      certificate: ca_cert,
      private_key: ca_key,
      subject: ca_subject
    }

    Mix.shell().info("")
    Mix.shell().info("Revoking certificate...")
    Mix.shell().info("CA: #{ca_subject}")
    Mix.shell().info("Serial Number: #{serial}")
    Mix.shell().info("Reason: #{reason}")
    Mix.shell().info("")

    # Check if certificate exists
    case GSMLG.PKI.Events.get_certificate_state(serial) do
      {:ok, %{status: :unknown}} ->
        Mix.shell().error([:red, "✗ Certificate not found"])
        Mix.shell().error("Serial #{serial} does not exist in the event log.")
        Mix.shell().error("Make sure the certificate was issued by this CA.")
        exit({:shutdown, 1})

      {:ok, %{status: :revoked, revocation_reason: prev_reason}} ->
        Mix.shell().error([:red, "✗ Certificate already revoked"])
        Mix.shell().error("Serial #{serial} was previously revoked.")
        Mix.shell().error("Reason: #{prev_reason}")
        exit({:shutdown, 1})

      {:ok, %{status: :expired}} ->
        Mix.shell().error([:yellow, "⚠️  Certificate is expired"])
        Mix.shell().error("Serial #{serial} has already expired.")
        Mix.shell().error("You may still revoke it if needed.")
        Mix.shell().info("")

        unless confirm("Revoke anyway?") do
          Mix.shell().info("Revocation cancelled.")
          exit({:shutdown, 0})
        end

      {:ok, %{status: :active, subject: subject}} ->
        Mix.shell().info("Certificate found:")
        Mix.shell().info("  Subject: #{subject}")
        Mix.shell().info("")

      {:error, reason} ->
        Mix.shell().error([:red, "✗ Error checking certificate"])
        Mix.shell().error("Error: #{inspect(reason)}")
        exit({:shutdown, 1})
    end

    # Revoke certificate
    case CA.revoke_certificate(ca, serial, reason: reason, actor: actor) do
      :ok ->
        Mix.shell().info([:green, "✓ Certificate revoked successfully!"])
        Mix.shell().info("")
        Mix.shell().info("Serial Number: #{serial}")
        Mix.shell().info("Reason: #{reason}")
        Mix.shell().info("Revoked By: #{actor}")
        Mix.shell().info("")

        Mix.shell().info(
          "Revocation has been logged to PostgreSQL for validation and CRL generation."
        )

        Mix.shell().info("")
        Mix.shell().info([:yellow, "⚠️  Remember to regenerate and distribute the CRL:"])

        Mix.shell().info(
          "  mix gsmlg.pki.crl.generate --ca-cert #{ca_cert_path} --ca-key #{ca_key_path}"
        )

      {:error, :already_revoked} ->
        Mix.shell().error([:red, "✗ Certificate already revoked"])
        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error([:red, "✗ Failed to revoke certificate"])
        Mix.shell().error("Error: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp parse_reason(reason_str) do
    case Map.get(@revocation_reasons, reason_str) do
      nil ->
        Mix.raise(
          "Invalid revocation reason '#{reason_str}'. " <>
            "Must be one of: #{Map.keys(@revocation_reasons) |> Enum.join(", ")}"
        )

      reason ->
        reason
    end
  end

  defp extract_subject(cert) do
    import GSMLG.PKI.ASN1
    otp_certificate(tbsCertificate: tbs) = cert
    subject_rdn = otp_tbs_certificate(tbs, :subject)
    GSMLG.PKI.RDNSequence.to_string(subject_rdn)
  end

  defp extract_ca_id(cert) do
    {:ok, cert_der} = Certificate.to_der(cert)
    hash = :crypto.hash(:sha256, cert_der)
    "ca:" <> (Base.encode16(hash, case: :lower) |> String.slice(0, 16))
  end

  defp missing_required(option) do
    Mix.raise("Required option #{option} is missing. Use --help for usage.")
  end

  defp confirm(message) do
    case Mix.shell().yes?("#{message} [y/n]") do
      true -> true
      false -> false
    end
  end
end
