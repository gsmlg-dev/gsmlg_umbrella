defmodule GSMLG.Commander.External.CommanderMTLSE2ETest do
  @moduledoc """
  Opt-in real authenticated Commander sessions against the production WSS listener.

  Credential contents and TLS error terms are deliberately excluded from test
  diagnostics. Use only dedicated trusted and untrusted client identities.
  """

  use ExUnit.Case, async: false

  alias GSMLG.Commander.Protocol.{Constants, Envelope}
  alias Phoenix.SocketClient.Channel

  @moduletag external: true
  @moduletag timeout: 45_000

  setup_all do
    assert required_env!("BROWSER_E2E_CONFIRM_REAL") == "yes",
           "set BROWSER_E2E_CONFIRM_REAL=yes only for the dedicated deployment"

    :ok = ensure_started(:ssl)
    url = required_env!("BROWSER_E2E_COMMANDER_WSS_URL")
    _uri = validate_wss_url!(url)

    %{
      url: url,
      commander_name: required_env!("BROWSER_E2E_COMMANDER_NAME"),
      credential_id: required_env!("BROWSER_E2E_COMMANDER_CREDENTIAL_ID"),
      credential_key: required_env!("BROWSER_E2E_COMMANDER_CREDENTIAL_KEY"),
      trusted: %{
        enabled: true,
        client_cert_file: required_env!("BROWSER_E2E_CLIENT_CERT_FILE"),
        client_key_file: required_env!("BROWSER_E2E_CLIENT_KEY_FILE"),
        ca_cert_file: required_env!("BROWSER_E2E_SERVER_CA_FILE")
      },
      untrusted: %{
        enabled: true,
        client_cert_file: required_env!("BROWSER_E2E_UNTRUSTED_CLIENT_CERT_FILE"),
        client_key_file: required_env!("BROWSER_E2E_UNTRUSTED_CLIENT_KEY_FILE"),
        ca_cert_file: required_env!("BROWSER_E2E_SERVER_CA_FILE")
      }
    }
  end

  test "real Commander listener accepts trusted mTLS and rejects missing and untrusted clients",
       ctx do
    trusted_options = socket_options!(ctx, ctx.trusted, :trusted_commander_socket)

    assert commander_session_succeeds?(trusted_options, ctx.commander_name),
           "trusted client did not complete WebSocket authentication and capability negotiation"

    without_client_identity =
      trusted_options
      |> update_in([:transport_opts, :ssl], fn ssl ->
        ssl |> Keyword.delete(:certfile) |> Keyword.delete(:keyfile)
      end)
      |> Keyword.put(:name, :missing_identity_commander_socket)

    refute commander_session_succeeds?(without_client_identity, ctx.commander_name),
           "Commander accepted an authenticated WebSocket session without a client certificate"

    untrusted_options = socket_options!(ctx, ctx.untrusted, :untrusted_commander_socket)

    refute commander_session_succeeds?(untrusted_options, ctx.commander_name),
           "Commander accepted an authenticated WebSocket session outside its client trust store"
  end

  defp socket_options!(ctx, tls, name) do
    GSMLG.Commander.socket_opts(
      platform_url: ctx.url,
      platform_key: ctx.credential_key,
      name: ctx.commander_name,
      credential_id: ctx.credential_id,
      tls: tls
    )
    |> Keyword.merge(name: name, reconnect?: false)
  end

  defp commander_session_succeeds?(options, commander_name) do
    Process.flag(:trap_exit, true)

    case Phoenix.SocketClient.start_link(options) do
      {:ok, socket} ->
        try do
          with true <- await_connected(socket, 10_000),
               {:ok, _join_reply, channel} <-
                 Channel.join(socket, "commander:#{commander_name}", %{}, 5_000),
               {:ok, %{"capabilities" => 1}} <-
                 Channel.push(channel, "message", version_negotiation(), 5_000),
               {:ok, _heartbeat_reply} <-
                 Channel.push(channel, "message", heartbeat(), 5_000) do
            true
          else
            _failure -> false
          end
        after
          if Process.alive?(socket), do: Supervisor.stop(socket, :normal, 5_000)
          flush_exit(socket)
        end

      {:error, _reason} ->
        false
    end
  catch
    :exit, _reason -> false
  end

  defp version_negotiation do
    %{
      "type" => "version.negotiation",
      "protocol_version" => Envelope.protocol_version(),
      "capabilities" => [
        %{
          "id" => "browser.control",
          "version" => 1,
          "backend" => "cloakbrowser_manager",
          "operations" => Constants.browser_control_operations(),
          "limits" => %{
            "max_profiles_running" => 1,
            "max_sessions" => 1,
            "max_workflows" => 1
          },
          "workflows" => ["gemini.deep_research/v1", "gemini.youtube_analysis/v1"]
        }
      ]
    }
  end

  defp heartbeat do
    %{
      "type" => "heartbeat",
      "protocol_version" => Envelope.protocol_version(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "capability_count" => 1
    }
  end

  defp await_connected(socket, remaining_ms) when remaining_ms > 0 do
    if Phoenix.SocketClient.connected?(socket) do
      true
    else
      Process.sleep(50)
      await_connected(socket, remaining_ms - 50)
    end
  end

  defp await_connected(_socket, _remaining_ms), do: false

  defp flush_exit(socket) do
    receive do
      {:EXIT, ^socket, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  defp validate_wss_url!(url) do
    case URI.parse(url) do
      %URI{scheme: "wss", host: host, userinfo: nil, query: nil, fragment: nil} = uri
      when is_binary(host) and host != "" ->
        uri

      _invalid ->
        raise "BROWSER_E2E_COMMANDER_WSS_URL must be a canonical WSS URL"
    end
  end

  defp required_env!(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _missing -> raise "missing required external E2E environment variable #{name}"
    end
  end

  defp ensure_started(application) do
    case Application.ensure_all_started(application) do
      {:ok, _started} -> :ok
      {:error, _reason} -> raise "could not start external E2E TLS dependency"
    end
  end
end
