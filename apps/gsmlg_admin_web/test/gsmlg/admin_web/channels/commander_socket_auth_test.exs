defmodule GSMLG.AdminWeb.CommanderSocketAuthTest do
  use GSMLG.AdminWeb.ChannelCase, async: false

  import ExUnit.CaptureLog

  alias GSMLG.AdminWeb.CommanderSocket

  setup do
    original = Application.fetch_env(:gsmlg_commander, GSMLG.Commander)
    secret = :crypto.strong_rand_bytes(32)

    config = [
      platform_credentials: %{
        "node-a-credential" => %{key: secret, commander_name: "node-a"}
      },
      auth_timestamp_window_seconds: 30
    ]

    Application.put_env(:gsmlg_commander, GSMLG.Commander, config)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:gsmlg_commander, GSMLG.Commander, value)
        :error -> Application.delete_env(:gsmlg_commander, GSMLG.Commander)
      end
    end)

    %{secret: secret}
  end

  test "authenticates a fresh signed nonce for its bound per-node credential", %{secret: secret} do
    params = signed_params(secret, "node-a", "node-a-credential")

    assert {:ok, socket} = connect_with_headers(params)
    assert socket.assigns.commander_name == "node-a"
    assert socket.assigns.credential_id == "node-a-credential"
    assert is_reference(socket.assigns.connection_id)
  end

  test "does not accept Commander credentials from URI query parameters", %{secret: secret} do
    params = signed_params(secret, "node-a", "node-a-credential")
    assert {:error, :missing_credentials} = Phoenix.ChannelTest.connect(CommanderSocket, params)
  end

  test "accepts per-node credential IDs decoded as atom TOML keys", %{secret: secret} do
    config = Application.fetch_env!(:gsmlg_commander, GSMLG.Commander)

    Application.put_env(
      :gsmlg_commander,
      GSMLG.Commander,
      Keyword.put(config, :platform_credentials, %{
        :"node-a-credential" => %{key: secret, commander_name: "node-a"}
      })
    )

    assert {:ok, socket} =
             secret
             |> signed_params("node-a", "node-a-credential")
             |> connect_with_headers()

    assert socket.assigns.commander_name == "node-a"
  end

  test "rejects a replayed nonce", %{secret: secret} do
    params = signed_params(secret, "node-a", "node-a-credential")

    assert {:ok, _socket} = connect_with_headers(params)
    assert {:error, :nonce_replayed} = connect_with_headers(params)
  end

  test "fails authentication safely when the nonce replay cache is at capacity", %{
    secret: secret
  } do
    replay = start_supervised!({GSMLG.CommandPlatform.ReplayCache, name: nil, max_entries: 1})
    config = Application.fetch_env!(:gsmlg_commander, GSMLG.Commander)

    Application.put_env(
      :gsmlg_commander,
      GSMLG.Commander,
      Keyword.put(config, :replay_cache, replay)
    )

    assert {:ok, _socket} =
             secret
             |> signed_params("node-a", "node-a-credential")
             |> connect_with_headers()

    assert {:error, :auth_capacity_reached} =
             secret
             |> signed_params("node-a", "node-a-credential")
             |> connect_with_headers()
  end

  test "rejects expired timestamps and a credential used for the wrong node", %{secret: secret} do
    expired =
      signed_params(secret, "node-a", "node-a-credential",
        sign_at: System.system_time(:second) - 31
      )

    wrong_node = signed_params(secret, "node-b", "node-a-credential")

    assert {:error, :expired_signature} = connect_with_headers(expired)

    assert {:error, :credential_identity_mismatch} =
             connect_with_headers(wrong_node)
  end

  test "rejects an invalid signature without emitting the signature value", %{secret: secret} do
    params = signed_params(secret, "node-a", "node-a-credential")
    invalid_signature = String.duplicate("F", 64)
    params = Map.put(params, "signature", invalid_signature)
    handler_id = "commander-auth-log-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:gsmlg, :log],
      fn _event, _measurements, metadata, pid -> send(pid, {:log, metadata}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      capture_log(fn ->
        assert {:error, :invalid_signature} = connect_with_headers(params)
      end)

    refute log =~ invalid_signature
    refute log =~ params["nonce"]
    refute log =~ params["sign_at"]
    assert_receive {:log, metadata}
    refute inspect(metadata) =~ invalid_signature
  end

  test "failed authentication does not log attacker supplied identity fields", %{secret: secret} do
    sentinel = "AUTH-IDENTITY-SECRET-#{System.unique_integer([:positive])}"
    params = signed_params(secret, sentinel, "#{sentinel}-credential")
    handler_id = "commander-auth-identity-log-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:gsmlg, :log],
      fn _event, _measurements, metadata, pid -> send(pid, {:auth_log, metadata}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      capture_log(fn ->
        assert {:error, :unknown_credential} =
                 connect_with_headers(params)

        assert_receive {:auth_log,
                        %{
                          message: "Commander socket signature verification failed",
                          error_code: :unknown_credential,
                          commander_name_size: commander_name_size,
                          credential_id_size: credential_id_size
                        } = metadata},
                       500

        assert commander_name_size == byte_size(sentinel)
        assert credential_id_size == byte_size("#{sentinel}-credential")
        refute inspect(metadata) =~ sentinel
      end)

    refute log =~ sentinel
  end

  test "rejects empty per-node credential material" do
    Application.put_env(:gsmlg_commander, GSMLG.Commander,
      platform_credentials: %{"empty" => %{key: "", commander_name: ""}}
    )

    params = signed_params("anything", "", "empty")
    assert {:error, :invalid_credential} = connect_with_headers(params)
  end

  test "does not accept the legacy shared platform key as server credentials", %{secret: secret} do
    Application.put_env(:gsmlg_commander, GSMLG.Commander,
      platform_key: secret,
      credential_id: "legacy",
      name: "node-a"
    )

    params = signed_params(secret, "node-a", "legacy")
    assert {:error, :unknown_credential} = connect_with_headers(params)
  end

  test "the endpoint disables connection logging and captures authenticated headers" do
    {_, _, opts} =
      Enum.find(GSMLG.AdminWeb.Endpoint.__sockets__(), fn {path, _, _} ->
        path == "/commander-socket"
      end)

    assert opts[:websocket][:log] == false
    assert :x_headers in opts[:websocket][:connect_info]

    filtered =
      Phoenix.Logger.filter_values(%{
        "signature" => "signature-secret",
        "nonce" => "nonce-secret",
        "sign_at" => "timestamp-secret"
      })

    assert filtered == %{
             "signature" => "[FILTERED]",
             "nonce" => "[FILTERED]",
             "sign_at" => "[FILTERED]"
           }
  end

  defp signed_params(secret, name, credential_id, opts \\ []) do
    sign_at = Keyword.get(opts, :sign_at, System.system_time(:second))

    nonce =
      Keyword.get(opts, :nonce, Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false))

    signed = "v1\n#{credential_id}\n#{name}\n#{sign_at}\n#{nonce}"

    %{
      "name" => name,
      "credential_id" => credential_id,
      "sign_at" => Integer.to_string(sign_at),
      "nonce" => nonce,
      "signature" => :crypto.mac(:hmac, :sha256, secret, signed) |> Base.encode16(case: :lower)
    }
  end

  defp connect_with_headers(params) do
    Phoenix.ChannelTest.connect(CommanderSocket, %{},
      connect_info: %{x_headers: auth_headers(params)}
    )
  end

  defp auth_headers(params) do
    [
      {"x-commander-name", params["name"]},
      {"x-commander-credential-id", params["credential_id"]},
      {"x-commander-sign-at", params["sign_at"]},
      {"x-commander-nonce", params["nonce"]},
      {"x-commander-signature", params["signature"]}
    ]
  end
end
