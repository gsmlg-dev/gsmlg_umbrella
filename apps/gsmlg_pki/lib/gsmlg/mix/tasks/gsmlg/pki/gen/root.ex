defmodule Mix.Tasks.Gsmlg.Pki.Gen.Root do
  @shortdoc "Generates a Root CA"

  @default_path "priv/ca/root"
  @default_name "GSMLG Root CA"

  @moduledoc """
  Generates Root CA for GSMLG.

      mix gsmlg.pki.gen.root
      mix gsmlg.pki.gen.root --serial 2 --after 2025-01-01 --before 2049-12-31 -o ./root

  Creates a private key and a self-signed certificate in PEM format. These
  files can be referenced in the `certfile` and `keyfile` parameters of an
  `:ssl` Root CA.

  ## Arguments

  Other (optional) arguments:

    * `--output` (`-o`): the path and base filename for the certificate and
      key (default: #{@default_path})
    * `--serial` (`-s`): the serial number for the CA
    * `--force` (`-f`): overwrite existing files without prompting for
      confirmation
    * `--before` (`-b`): the start date of the certificate
      (default: 2025-01-01)
    * `--after` (`-a`): the end date of the certificate
      (default: 2049-12-31)

  Requires OTP 21 or later.
  """

  use Mix.Task
  import Mix.Generator

  @doc false
  def run(all_args) do
    _ = Application.ensure_all_started(:gsmlg_pki)

    {opts, _args} =
      OptionParser.parse!(
        all_args,
        aliases: [s: :serial, o: :output, f: :force, b: :before, a: :after],
        strict: [
          serial: :integer,
          output: :string,
          force: :boolean,
          before: :string,
          after: :string
        ]
      )

    serial = opts[:serial] || 1
    name = "#{@default_name} #{serial}"
    path = opts[:output] || @default_path
    force = opts[:force] || false
    nafter = opts[:before] || "2049-12-31"
    nbefore = opts[:after] || "2025-01-01"

    {:ok, not_before, _} = DateTime.from_iso8601("#{nbefore}T00:00:00Z")
    {:ok, not_after, _} = DateTime.from_iso8601("#{nafter}T23:59:59Z")
    validity = GSMLG.PKI.Certificate.Validity.new(not_before, not_after)

    {certificate, private_key} = certificate_and_key(4096, name, serial, validity)

    keyfile = path <> "_#{serial}_key.pem"
    certfile = path <> "_#{serial}.pem"

    create_file(keyfile, GSMLG.PKI.PrivateKey.to_pem(private_key), force: force)
    create_file(certfile, GSMLG.PKI.Certificate.to_pem(certificate), force: force)

    print_shell_instructions(keyfile, certfile)
  end

  @doc false
  def certificate_and_key(key_size, name, serial, validity) do
    private_key = GSMLG.PKI.PrivateKey.new_rsa(key_size)

    certificate =
      GSMLG.PKI.Certificate.self_signed(
        private_key,
        "/C=CN/ST=BJ/L=Chaoyang District/O=GSMLG/CN=#{name}",
        template: :root_ca,
        serial: serial,
        validity: validity,
        extensions: []
      )

    {certificate, private_key}
  end

  defp print_shell_instructions(keyfile, certfile) do
    Mix.shell().info("""

    Root CA and private key generated:

        [certfile: "#{certfile}", keyfile: "#{keyfile}"]

    # Root CA Certificate info:

    #{File.read!(certfile) |> GSMLG.PKI.Certificate.from_pem!() |> inspect(limit: :infinity, pretty: true)}
    """)
  end
end
