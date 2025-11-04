defmodule Mix.Tasks.Gsmlg.Pki.Crl.Generate do
  use Mix.Task

  @shortdoc "Generate a Certificate Revocation List (CRL)"

  @moduledoc """
  Generate a Certificate Revocation List (CRL) from revocation events.

  ## Usage

      mix gsmlg.pki.crl.generate [options]

  ## Options

      --ca-cert       - Path to CA certificate (required)
      --ca-key        - Path to CA private key (required)
      --output        - Output CRL file (default: ca.crl)
      --format        - Output format: der or pem (default: der)
      --validity      - CRL validity in days (default: 7)

  ## Examples

      # Generate CRL in DER format
      mix gsmlg.pki.crl.generate \\
        --ca-cert ca/ca-cert.pem \\
        --ca-key ca/ca-key.pem \\
        --output ca.crl

      # Generate CRL in PEM format
      mix gsmlg.pki.crl.generate \\
        --ca-cert ca/ca-cert.pem \\
        --ca-key ca/ca-key.pem \\
        --output ca.crl.pem \\
        --format pem

      # Generate CRL valid for 30 days
      mix gsmlg.pki.crl.generate \\
        --ca-cert ca/ca-cert.pem \\
        --ca-key ca/ca-key.pem \\
        --output ca.crl \\
        --validity 30

  ## Distribution

  The generated CRL should be distributed to clients that need to check
  certificate revocation status. Common distribution methods:

  1. HTTP distribution:
     - Place the CRL file on a web server
     - Update the CRL Distribution Point in certificates

  2. LDAP distribution:
     - Upload to LDAP directory
     - Reference in certificate extensions

  3. File distribution:
     - Include in application bundles
     - Update via software updates

  ## Automation

  CRL generation should be automated to run periodically (e.g., daily or weekly)
  to ensure revocation information stays current.

  Example cron job:

      0 0 * * * cd /path/to/app && mix gsmlg.pki.crl.generate \\
        --ca-cert ca/ca-cert.pem \\
        --ca-key ca/ca-key.pem \\
        --output /var/www/ca.crl

  ## Event Logging

  CRL generation is logged to PostgreSQL as an immutable event with:
  - CRL number
  - This update and next update timestamps
  - Number of revoked certificates
  - CRL size

  This provides complete audit trail of CRL generation.
  """

  alias GSMLG.PKI.{CA, Certificate, PrivateKey, CRL}

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          ca_cert: :string,
          ca_key: :string,
          output: :string,
          format: :string,
          validity: :integer
        ]
      )

    # Validate required options
    ca_cert_path = Keyword.get(opts, :ca_cert) || missing_required("--ca-cert")
    ca_key_path = Keyword.get(opts, :ca_key) || missing_required("--ca-key")

    # Parse options with defaults
    output = Keyword.get(opts, :output, "ca.crl")
    format = parse_format(Keyword.get(opts, :format, "der"))
    validity = Keyword.get(opts, :validity, 7)

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
    Mix.shell().info("Generating Certificate Revocation List...")
    Mix.shell().info("CA: #{ca_subject}")
    Mix.shell().info("Validity: #{validity} days")
    Mix.shell().info("")

    # Generate CRL
    case CA.generate_crl(ca, validity: validity) do
      {:ok, crl} ->
        # Serialize CRL
        crl_data =
          case format do
            :der ->
              {:ok, der} = CRL.to_der(crl)
              der

            :pem ->
              {:ok, pem} = CRL.to_pem(crl)
              pem
          end

        # Write to file
        File.write!(output, crl_data)

        # Get revocation count
        {:ok, revocations} = GSMLG.PKI.Events.get_revocations(ca.id)
        revoked_count = length(revocations)

        # Calculate next update time
        next_update = DateTime.add(DateTime.utc_now(), validity, :day)

        # Success message
        Mix.shell().info([:green, "✓ CRL generated successfully!"])
        Mix.shell().info("")
        Mix.shell().info("Output: #{output}")
        Mix.shell().info("Format: #{format |> Atom.to_string() |> String.upcase()}")
        Mix.shell().info("Size: #{byte_size(crl_data)} bytes")
        Mix.shell().info("Revoked Certificates: #{revoked_count}")
        Mix.shell().info("This Update: #{DateTime.utc_now() |> DateTime.to_iso8601()}")

        Mix.shell().info("Next Update: #{next_update |> DateTime.to_iso8601()}")

        Mix.shell().info("")

        if revoked_count == 0 do
          Mix.shell().info([:yellow, "⚠️  No revoked certificates in this CRL"])
        end

        Mix.shell().info("CRL generation has been logged to PostgreSQL.")
        Mix.shell().info("")
        Mix.shell().info("Next steps:")
        Mix.shell().info("  1. Distribute the CRL to clients")
        Mix.shell().info("  2. Update CRL Distribution Points if needed")

        Mix.shell().info("  3. Schedule automatic regeneration (recommended: daily or weekly)")

      {:error, reason} ->
        Mix.shell().error([:red, "✗ Failed to generate CRL"])
        Mix.shell().error("Error: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp parse_format("der"), do: :der
  defp parse_format("pem"), do: :pem

  defp parse_format(format) do
    Mix.raise("Invalid format '#{format}'. Must be 'der' or 'pem'")
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
end
