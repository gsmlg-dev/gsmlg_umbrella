defmodule GSMLG.Commander.TLSTest do
  use ExUnit.Case, async: true

  alias GSMLG.Commander.TLS

  @moduletag :tmp_dir

  test "builds peer- and hostname-verifying client mTLS options", %{tmp_dir: tmp_dir} do
    paths = write_credentials(tmp_dir, test_credentials())

    assert {:ok, transport_opts} =
             TLS.transport_opts("wss://commander.example.test/socket", tls(paths))

    ssl = Keyword.fetch!(transport_opts, :ssl)

    assert ssl[:verify] == :verify_peer
    assert ssl[:server_name_indication] == ~c"commander.example.test"
    assert is_function(ssl[:customize_hostname_check][:match_fun], 2)
    assert ssl[:certfile] == String.to_charlist(paths.cert)
    assert ssl[:keyfile] == String.to_charlist(paths.key)
    assert ssl[:cacertfile] == String.to_charlist(paths.ca)
    assert ssl[:versions] == [:"tlsv1.3", :"tlsv1.2"]
  end

  test "reports only bounded client certificate validity for the live connection", %{
    tmp_dir: tmp_dir
  } do
    credentials = test_credentials(validity: {{2026, 9, 1}, {2026, 9, 10}})
    paths = write_credentials(tmp_dir, credentials)

    assert %{
             "status" => "verified",
             "certificate_expires_at" => "2026-09-10T" <> _time
           } =
             TLS.connection_summary(
               "wss://commander.example.test/socket",
               tls(paths),
               ~U[2026-09-06 12:00:00Z]
             )

    summary = inspect(TLS.connection_summary("wss://commander.example.test/socket", tls(paths)))
    refute summary =~ paths.cert
    refute summary =~ paths.key
    refute summary =~ Base.encode64(credentials[:cert])
  end

  test "requires wss when mTLS is enabled", %{tmp_dir: tmp_dir} do
    paths = write_credentials(tmp_dir, test_credentials())

    assert {:error, :mtls_requires_wss} =
             TLS.transport_opts("ws://commander.example.test/socket", tls(paths))
  end

  test "rejects a malformed secure URL instead of crashing or falling back" do
    assert {:error, :invalid_commander_url} = TLS.transport_opts("wss:///socket", enabled: false)
  end

  test "rejects missing or unreadable client credential files", %{tmp_dir: tmp_dir} do
    paths = write_credentials(tmp_dir, test_credentials())

    assert {:error, {:client_cert_file_unreadable, _path}} =
             TLS.transport_opts(
               "wss://commander.example.test/socket",
               tls(%{paths | cert: Path.join(tmp_dir, "missing.pem")})
             )

    assert {:error, {:client_key_file_unreadable, _path}} =
             TLS.transport_opts(
               "wss://commander.example.test/socket",
               tls(%{paths | key: Path.join(tmp_dir, "missing-key.pem")})
             )
  end

  test "rejects a client certificate and private key that do not match", %{tmp_dir: tmp_dir} do
    credentials = test_credentials()
    other_credentials = test_credentials()
    paths = write_credentials(tmp_dir, credentials)
    other_paths = write_credentials(Path.join(tmp_dir, "other"), other_credentials)

    assert {:error, :client_certificate_key_mismatch} =
             TLS.transport_opts(
               "wss://commander.example.test/socket",
               tls(%{paths | key: other_paths.key})
             )
  end

  test "never falls back to insecure transport after credential validation fails", %{
    tmp_dir: tmp_dir
  } do
    paths = write_credentials(tmp_dir, test_credentials())
    File.write!(paths.cert, "not-a-certificate")

    assert {:error, :invalid_client_certificate} =
             TLS.transport_opts("wss://commander.example.test/socket", tls(paths))
  end

  test "rejects expired and not-yet-valid client certificates", %{tmp_dir: tmp_dir} do
    expired = test_credentials(validity: {{2020, 1, 1}, {2020, 1, 2}})
    future = test_credentials(validity: {{2030, 1, 1}, {2030, 1, 2}})

    expired_paths = write_credentials(Path.join(tmp_dir, "expired"), expired)
    future_paths = write_credentials(Path.join(tmp_dir, "future"), future)

    assert {:error, :client_certificate_expired} =
             TLS.transport_opts("wss://commander.example.test/socket", tls(expired_paths))

    assert {:error, :client_certificate_not_yet_valid} =
             TLS.transport_opts("wss://commander.example.test/socket", tls(future_paths))
  end

  test "a mutual TLS listener accepts the configured client and rejects missing or untrusted certificates",
       %{tmp_dir: tmp_dir} do
    credentials =
      :public_key.pkix_test_data(%{
        server_chain: %{root: [digest: :sha256], peer: [digest: :sha256]},
        client_chain: %{root: [digest: :sha256], peer: [digest: :sha256]}
      })

    trusted_paths = write_credentials(Path.join(tmp_dir, "trusted"), credentials.client_config)
    hostname = :net_adm.localhost() |> to_string()

    assert {:ok, transport_opts} =
             TLS.transport_opts("wss://#{hostname}/socket", tls(trusted_paths))

    assert {{:ok, _socket}, :ok} =
             connect_to_mutual_tls_listener(
               credentials.server_config,
               Keyword.put(transport_opts[:ssl], :versions, [:"tlsv1.2"])
             )

    client_without_certificate =
      transport_opts[:ssl]
      |> Keyword.delete(:certfile)
      |> Keyword.delete(:keyfile)

    assert {{:error, _client_reason}, {:error, _server_reason}} =
             connect_to_mutual_tls_listener(
               credentials.server_config,
               Keyword.put(client_without_certificate, :versions, [:"tlsv1.2"])
             )

    untrusted_credentials = test_credentials()
    untrusted_paths = write_credentials(Path.join(tmp_dir, "untrusted"), untrusted_credentials)

    assert {:ok, untrusted_transport_opts} =
             TLS.transport_opts(
               "wss://#{hostname}/socket",
               tls(%{untrusted_paths | ca: trusted_paths.ca})
             )

    assert {{:error, _client_reason}, {:error, _server_reason}} =
             connect_to_mutual_tls_listener(
               credentials.server_config,
               Keyword.put(untrusted_transport_opts[:ssl], :versions, [:"tlsv1.2"])
             )
  end

  test "certificate rotation invokes only the injected connection restart", %{tmp_dir: tmp_dir} do
    paths = write_credentials(tmp_dir, test_credentials())
    test_pid = self()
    unrelated = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(unrelated, :kill) end)

    _watcher =
      start_supervised!(
        {TLS,
         name: nil,
         url: "wss://commander.example.test/socket",
         tls: tls(paths),
         reload_interval_ms: 10,
         restart_fun: fn ->
           send(test_pid, :connection_restarted)
           :ok
         end}
      )

    Process.sleep(20)
    write_credentials(tmp_dir, test_credentials())

    assert_receive :connection_restarted, 250
    assert Process.alive?(unrelated)
  end

  test "failed certificate restart is retried before accepting the new fingerprint", %{
    tmp_dir: tmp_dir
  } do
    paths = write_credentials(tmp_dir, test_credentials())
    test_pid = self()
    attempts = :counters.new(1, [])

    _watcher =
      start_supervised!(
        {TLS,
         name: nil,
         url: "wss://commander.example.test/socket",
         tls: tls(paths),
         reload_interval_ms: 10,
         restart_fun: fn ->
           :counters.add(attempts, 1, 1)
           attempt = :counters.get(attempts, 1)
           send(test_pid, {:restart_attempt, attempt})
           if attempt == 1, do: {:error, :restart_failed}, else: :ok
         end}
      )

    write_credentials(tmp_dir, test_credentials())

    assert_receive {:restart_attempt, 1}, 250
    assert_receive {:restart_attempt, 2}, 250
    refute_receive {:restart_attempt, 3}, 50
  end

  defp tls(paths) do
    [
      enabled: true,
      client_cert_file: paths.cert,
      client_key_file: paths.key,
      ca_cert_file: paths.ca,
      reload_interval_ms: 10
    ]
  end

  defp test_credentials(peer_options \\ []) do
    :public_key.pkix_test_data(%{
      root: [digest: :sha256],
      peer: Keyword.put_new(peer_options, :digest, :sha256)
    })
  end

  defp write_credentials(dir, credentials) do
    File.mkdir_p!(dir)
    cert_path = Path.join(dir, "client-chain.pem")
    key_path = Path.join(dir, "client-key.pem")
    ca_path = Path.join(dir, "ca.pem")

    File.write!(
      cert_path,
      :public_key.pem_encode([{:Certificate, credentials[:cert], :not_encrypted}])
    )

    {key_type, key_der} = credentials[:key]
    File.write!(key_path, :public_key.pem_encode([{key_type, key_der, :not_encrypted}]))

    ca_entries = Enum.map(credentials[:cacerts], &{:Certificate, &1, :not_encrypted})
    File.write!(ca_path, :public_key.pem_encode(ca_entries))

    %{cert: cert_path, key: key_path, ca: ca_path}
  end

  defp connect_to_mutual_tls_listener(server_config, client_config) do
    listener_options =
      Keyword.merge(server_config,
        active: false,
        reuseaddr: true,
        verify: :verify_peer,
        fail_if_no_peer_cert: true,
        versions: [:"tlsv1.2"]
      )

    {:ok, listener} = :ssl.listen(0, listener_options)
    {:ok, {_address, port}} = :ssl.sockname(listener)
    owner = self()

    acceptor =
      spawn_link(fn ->
        result =
          with {:ok, socket} <- :ssl.transport_accept(listener, 2_000),
               {:ok, socket} <- :ssl.handshake(socket, 2_000) do
            :ok = :ssl.close(socket)
            :ok
          end

        send(owner, {:tls_server_handshake, self(), result})
      end)

    client_result = :ssl.connect(~c"localhost", port, client_config, 2_000)

    server_result =
      receive do
        {:tls_server_handshake, ^acceptor, result} -> result
      after
        2_500 -> {:error, :server_handshake_timeout}
      end

    :ok = :ssl.close(listener)
    {client_result, server_result}
  end
end
