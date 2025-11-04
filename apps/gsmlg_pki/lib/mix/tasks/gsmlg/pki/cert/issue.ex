defmodule Mix.Tasks.Gsmlg.Pki.Cert.Issue do
  use Mix.Task

  @shortdoc "Issue a certificate from a CA"

  @moduledoc """
  Issue a certificate from an existing Certificate Authority.

  ## Usage

      mix gsmlg.pki.cert.issue [options]

  ## Options

      --ca-cert       - Path to CA certificate (required)
      --ca-key        - Path to CA private key (required)
      --csr           - Path to Certificate Signing Request (CSR) file
      --subject       - Certificate subject DN (if no CSR)
      --template      - Certificate template: server, client (default: server)
      --validity      - Validity in days (default: 365)
      --san           - Subject Alternative Names (comma-separated)
                        Example: "example.com,www.example.com,mail.example.com"
      --output        - Output certificate file (default: cert.pem)
      --actor         - Who is issuing the certificate (default: system)

  ## Examples

      # Issue certificate from CSR
      mix gsmlg.pki.cert.issue \\
        --ca-cert ca/ca-cert.pem \\
        --ca-key ca/ca-key.pem \\
        --csr server.csr \\
        --output server-cert.pem

      # Issue certificate with SAN
      mix gsmlg.pki.cert.issue \\
        --ca-cert ca/ca-cert.pem \\
        --ca-key ca/ca-key.pem \\
        --csr server.csr \\
        --san "example.com,www.example.com" \\
        --output server-cert.pem

      # Issue client certificate (2-year validity)
      mix gsmlg.pki.cert.issue \\
        --ca-cert ca/ca-cert.pem \\
        --ca-key ca/ca-key.pem \\
        --csr client.csr \\
        --template client \\
        --validity 730 \\
        --output client-cert.pem

  ## Templates

      server    - TLS server certificate (serverAuth)
      client    - TLS client certificate (clientAuth)

  ## Output

  The issued certificate is written to the output file in PEM format.
  The certificate is also logged to PostgreSQL for audit and revocation tracking.

  ## Event Logging

  Certificate issuance is logged to PostgreSQL as an immutable event with:
  - Serial number
  - Subject and issuer
  - Template and extensions
  - Validity period
  - Actor (who issued it)

  This enables:
  - Complete audit trail
  - Revocation checking
  - Certificate lifecycle tracking
  """

  alias GSMLG.PKI.{CA, Certificate, PrivateKey}

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          ca_cert: :string,
          ca_key: :string,
          csr: :string,
          subject: :string,
          template: :string,
          validity: :integer,
          san: :string,
          output: :string,
          actor: :string
        ]
      )

    # Validate required options
    ca_cert_path = Keyword.get(opts, :ca_cert) || missing_required("--ca-cert")
    ca_key_path = Keyword.get(opts, :ca_key) || missing_required("--ca-key")
    csr_path = Keyword.get(opts, :csr) || missing_required("--csr")

    # Parse options with defaults
    template = parse_template(Keyword.get(opts, :template, "server"))
    validity = Keyword.get(opts, :validity, 365)
    san = parse_san(Keyword.get(opts, :san))
    output = Keyword.get(opts, :output, "cert.pem")
    actor = Keyword.get(opts, :actor, "system")

    # Load CA certificate and key
    Mix.shell().info("Loading CA certificate and key...")

    ca_cert_pem = File.read!(ca_cert_path)
    ca_key_pem = File.read!(ca_key_path)

    {:ok, ca_cert} = Certificate.from_pem(ca_cert_pem)
    {:ok, ca_key} = PrivateKey.from_pem(ca_key_pem)

    # Extract CA info for display
    ca_subject = extract_subject(ca_cert)

    # Create CA structure
    ca = %{
      id: extract_ca_id(ca_cert),
      certificate: ca_cert,
      private_key: ca_key,
      subject: ca_subject
    }

    # Load CSR
    Mix.shell().info("Loading Certificate Signing Request...")
    csr_pem = File.read!(csr_path)

    Mix.shell().info("")
    Mix.shell().info("Issuing certificate...")
    Mix.shell().info("CA: #{ca_subject}")
    Mix.shell().info("Template: #{template}")
    Mix.shell().info("Validity: #{validity} days")

    if san do
      Mix.shell().info("SAN: #{Enum.join(san, ", ")}")
    end

    Mix.shell().info("")

    # Build extensions
    extensions = if san, do: [subject_alt_name: san], else: []

    # Issue certificate
    case CA.issue_certificate(ca, csr_pem,
           template: template,
           validity: validity,
           extensions: extensions,
           actor: actor
         ) do
      {:ok, cert} ->
        # Save certificate
        {:ok, cert_pem} = Certificate.to_pem(cert)
        File.write!(output, cert_pem)

        # Extract info for display
        serial = extract_serial(cert)
        subject = extract_subject(cert)

        # Success message
        Mix.shell().info([:green, "✓ Certificate issued successfully!"])
        Mix.shell().info("")
        Mix.shell().info("Serial Number: #{serial}")
        Mix.shell().info("Subject: #{subject}")
        Mix.shell().info("Output: #{output}")
        Mix.shell().info("")
        Mix.shell().info("Certificate has been logged to PostgreSQL for revocation tracking.")

      {:error, reason} ->
        Mix.shell().error([:red, "✗ Failed to issue certificate"])
        Mix.shell().error("Error: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp parse_template("server"), do: :server
  defp parse_template("client"), do: :client

  defp parse_template(template) do
    Mix.raise("Invalid template '#{template}'. Must be 'server' or 'client'")
  end

  defp parse_san(nil), do: nil

  defp parse_san(san_string) do
    san_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp extract_subject(cert) do
    import GSMLG.PKI.ASN1
    otp_certificate(tbsCertificate: tbs) = cert
    subject_rdn = otp_tbs_certificate(tbs, :subject)
    GSMLG.PKI.RDNSequence.to_string(subject_rdn)
  end

  defp extract_serial(cert) do
    import GSMLG.PKI.ASN1
    otp_certificate(tbsCertificate: tbs) = cert
    otp_tbs_certificate(serialNumber: serial) = tbs
    serial
  end

  defp extract_ca_id(cert) do
    # Generate CA ID from certificate
    {:ok, cert_der} = Certificate.to_der(cert)
    hash = :crypto.hash(:sha256, cert_der)
    "ca:" <> (Base.encode16(hash, case: :lower) |> String.slice(0, 16))
  end

  defp missing_required(option) do
    Mix.raise("Required option #{option} is missing. Use --help for usage.")
  end
end
