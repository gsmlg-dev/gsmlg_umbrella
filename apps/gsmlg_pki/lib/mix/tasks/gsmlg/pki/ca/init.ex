defmodule Mix.Tasks.Gsmlg.Pki.Ca.Init do
  use Mix.Task

  @shortdoc "Initialize a new Certificate Authority"

  @moduledoc """
  Initialize a new Certificate Authority with event sourcing.

  ## Usage

      mix gsmlg.pki.ca.init [options]

  ## Options

      --subject       - CA subject DN (required)
                        Example: "/CN=My CA/O=My Org/C=US"
      --key-type      - Key type: rsa or ec (default: rsa)
      --key-size      - RSA key size: 2048, 3072, 4096, 8192 (default: 4096)
      --curve         - EC curve: secp256r1, secp384r1, secp521r1 (default: secp384r1)
      --validity      - Validity in days (default: 7300 = 20 years)
      --output        - Output directory for CA files (default: ./ca)
      --actor         - Who is creating the CA (default: system)

  ## Examples

      # Create RSA 4096-bit root CA
      mix gsmlg.pki.ca.init --subject "/CN=GSMLG Root CA/O=GSMLG/C=US"

      # Create EC root CA with custom curve
      mix gsmlg.pki.ca.init \\
        --subject "/CN=EC CA/O=GSMLG" \\
        --key-type ec \\
        --curve secp256r1

      # Create CA valid for 10 years
      mix gsmlg.pki.ca.init \\
        --subject "/CN=Short CA" \\
        --validity 3650

  ## Output

  The task creates the following files in the output directory:

      ca-cert.pem     - CA certificate (PEM format)
      ca-key.pem      - CA private key (PEM format, mode 0600)
      ca-info.txt     - CA information and ID

  ## Security

  The private key file (ca-key.pem) is created with permissions 0600.
  Store this file securely and back it up safely. If lost, you cannot
  issue new certificates with this CA.

  ## Event Logging

  CA initialization is logged to CouchDB as an immutable event with:
  - Timestamp
  - CA subject and ID
  - Key type and size
  - Actor (who created it)
  - Certificate details

  This provides a complete audit trail of CA creation.
  """

  alias GSMLG.PKI.{CA, Certificate, PrivateKey}

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          subject: :string,
          key_type: :string,
          key_size: :integer,
          curve: :string,
          validity: :integer,
          output: :string,
          actor: :string
        ]
      )

    # Validate required options
    subject = Keyword.get(opts, :subject) || missing_required("--subject")

    # Parse options with defaults
    key_type = parse_key_type(Keyword.get(opts, :key_type, "rsa"))
    key_size = Keyword.get(opts, :key_size, 4096)
    curve = parse_curve(Keyword.get(opts, :curve, "secp384r1"))
    validity = Keyword.get(opts, :validity, 7300)
    output_dir = Keyword.get(opts, :output, "./ca")
    actor = Keyword.get(opts, :actor, "system")

    # Validate key size for RSA
    if key_type == :rsa and key_size not in [2048, 3072, 4096, 8192] do
      Mix.raise("Invalid RSA key size. Must be one of: 2048, 3072, 4096, 8192")
    end

    Mix.shell().info("Initializing Certificate Authority...")
    Mix.shell().info("Subject: #{subject}")
    Mix.shell().info("Key Type: #{key_type}")

    if key_type == :rsa do
      Mix.shell().info("Key Size: #{key_size} bits")
    else
      Mix.shell().info("Curve: #{curve}")
    end

    Mix.shell().info("Validity: #{validity} days (#{Float.round(validity / 365.25, 1)} years)")
    Mix.shell().info("")

    # Initialize CA
    case CA.initialize(subject,
           key_type: key_type,
           key_size: key_size,
           curve: curve,
           validity: validity,
           actor: actor
         ) do
      {:ok, ca} ->
        # Create output directory
        File.mkdir_p!(output_dir)

        # Save certificate
        {:ok, cert_pem} = Certificate.to_pem(ca.certificate)
        cert_path = Path.join(output_dir, "ca-cert.pem")
        File.write!(cert_path, cert_pem)

        # Save private key
        {:ok, key_pem} = PrivateKey.to_pem(ca.private_key)
        key_path = Path.join(output_dir, "ca-key.pem")
        File.write!(key_path, key_pem)
        File.chmod!(key_path, 0o600)

        # Save CA info
        info = """
        Certificate Authority Information
        ==================================

        CA ID: #{ca.id}
        Subject: #{ca.subject}
        Key Type: #{key_type}
        #{if key_type == :rsa, do: "Key Size: #{key_size} bits", else: "Curve: #{curve}"}
        Validity: #{validity} days
        Created: #{DateTime.utc_now() |> DateTime.to_iso8601()}
        Created By: #{actor}

        Files:
          Certificate: #{cert_path}
          Private Key: #{key_path} (mode 0600)

        Security Notice:
          The private key is highly sensitive. Store it securely and create backups.
          If lost, you will not be able to issue certificates with this CA.

        Next Steps:
          1. Backup the private key to a secure location
          2. Distribute the CA certificate to clients who need to trust it
          3. Use 'mix gsmlg.pki.cert.issue' to issue certificates

        Event Logging:
          CA initialization has been logged to CouchDB with complete audit trail.
        """

        info_path = Path.join(output_dir, "ca-info.txt")
        File.write!(info_path, info)

        # Success message
        Mix.shell().info([:green, "✓ Certificate Authority initialized successfully!"])
        Mix.shell().info("")
        Mix.shell().info("CA ID: #{ca.id}")
        Mix.shell().info("Certificate: #{cert_path}")
        Mix.shell().info("Private Key: #{key_path} (mode 0600 - keep secure!)")
        Mix.shell().info("Info: #{info_path}")
        Mix.shell().info("")
        Mix.shell().info([:yellow, "⚠️  IMPORTANT: Backup the private key securely!"])

      {:error, reason} ->
        Mix.shell().error([:red, "✗ Failed to initialize CA"])
        Mix.shell().error("Error: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp parse_key_type("rsa"), do: :rsa
  defp parse_key_type("ec"), do: :ec

  defp parse_key_type(type) do
    Mix.raise("Invalid key type '#{type}'. Must be 'rsa' or 'ec'")
  end

  defp parse_curve("secp256r1"), do: :secp256r1
  defp parse_curve("secp384r1"), do: :secp384r1
  defp parse_curve("secp521r1"), do: :secp521r1
  defp parse_curve("prime256v1"), do: :secp256r1  # Alias

  defp parse_curve(curve) do
    Mix.raise(
      "Invalid curve '#{curve}'. Must be one of: secp256r1, secp384r1, secp521r1"
    )
  end

  defp missing_required(option) do
    Mix.raise("Required option #{option} is missing. Use --help for usage.")
  end
end
