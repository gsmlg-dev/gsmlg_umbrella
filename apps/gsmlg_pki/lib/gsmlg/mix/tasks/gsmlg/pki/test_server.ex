defmodule Mix.Tasks.Gsmlg.Pki.TestServer do
  @shortdoc "Runs a server for manual TLS client testing"

  @moduledoc """
  Runs a server for manual TLS client testing

      mix gsmlg.pki.test_server
      mix gsmlg.pki.test_server test.local

  Please refer to the documentation for `GSMLG.PKI.Test.Suite` for information about
  the scenarios that may be tested using the server.

  Requires OTP 20 or later.
  """

  use Mix.Task

  @http_response ["HTTP/1.1 200 OK", "Content-Length: 2", "Connection: close", "", "OK"]
                 |> Enum.join("\r\n")

  @doc false
  def run(all_args) do
    {_opts, args} =
      OptionParser.parse!(
        all_args,
        aliases: [],
        strict: []
      )

    # Start the CRL responder
    {:ok, crl_server_pid} = GSMLG.PKI.Test.CRLServer.start_link([])
    crl_server_port = GSMLG.PKI.Test.CRLServer.get_port(crl_server_pid)
    crl_server_uri = "http://localhost:#{crl_server_port}/"

    suite =
      case args do
        [] -> GSMLG.PKI.Test.Suite.new(crl_server: crl_server_uri)
        [domain] -> GSMLG.PKI.Test.Suite.new(crl_server: crl_server_uri, domain: domain)
      end

    cacertfile = write_cacerts!("cacerts.pem", suite.cacerts)
    Mix.shell().info("Primary CA certificate store: #{cacertfile}")
    alternate_cacertfile = write_cacerts!("alternate_cacerts.pem", suite.alternate_cacerts)
    Mix.shell().info("Secondary CA certificate store: #{alternate_cacertfile}")

    client_certfile = write_cert!("client.pem", suite.client)
    write_key!("client_key.pem", suite.client_key)
    Mix.shell().info("Client certificate and key: #{client_certfile} / [...]/client_key.pem")

    # Update the CRL server with the generated CRLs
    suite.crls
    |> Enum.each(fn {path, crl} ->
      GSMLG.PKI.Test.CRLServer.put_crl(crl_server_pid, "/#{path}", crl)
    end)

    # Start the test server with a canned HTTP response, and get the TCP port
    # number of the server
    {:ok, pid} = GSMLG.PKI.Test.Server.start_link({suite, [response: @http_response]})
    port = GSMLG.PKI.Test.Server.get_port(pid)

    Mix.shell().info("""
    Server is running on port #{port}.

    Sample invocation of `curl`:
      curl --cacert #{cacertfile} https://valid.#{suite.domain}:#{port}/

    Please refer to the documentation for GSMLG.PKI.Test.Suite for a list of
    available endpoints and their expected behaviour.
    """)

    unless iex_running?(), do: Process.sleep(:infinity)
  end

  defp write_cacerts!(filename, certs) do
    pem =
      certs
      |> Enum.map(&certificate_der_to_pem/1)
      |> Enum.join()

    path = Path.join(System.tmp_dir!(), filename)
    File.write!(path, pem)
    path
  end

  defp write_cert!(filename, cert) do
    path = Path.join(System.tmp_dir!(), filename)
    File.write!(path, GSMLG.PKI.Certificate.to_pem(cert))
    path
  end

  defp write_key!(filename, key) do
    path = Path.join(System.tmp_dir!(), filename)
    File.write!(path, GSMLG.PKI.PrivateKey.to_pem(key))
    path
  end

  defp certificate_der_to_pem(der) do
    der
    |> GSMLG.PKI.Certificate.from_der!()
    |> GSMLG.PKI.Certificate.to_pem()
  end

  defp iex_running? do
    Code.ensure_loaded?(IEx) and IEx.started?()
  end
end
