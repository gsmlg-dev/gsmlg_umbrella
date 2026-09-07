defmodule GSMLG.BrowserAgent.External.CloakBrowserE2ETest do
  @moduledoc """
  Destructive, opt-in checks for a dedicated NixOS/Podman CloakBrowser v0.1.5 node.

  Run on the remote Browser Agent host with:

      mix test --include external apps/gsmlg_browser_agent/test/external/cloak_browser_e2e_test.exs

  The test refuses to run without an explicit confirmation and dedicated profile.
  """

  use ExUnit.Case, async: false

  alias GSMLG.BrowserAgent.Backends.CloakBrowser
  alias GSMLG.BrowserAgent.Settings

  @moduletag external: true
  @moduletag timeout: 120_000
  @sensitive_profile_keys ~w(
    cdp_url
    fingerprint_seed
    password
    proxy
    token
    user_data_dir
  )

  setup_all do
    assert required_env!("BROWSER_E2E_CONFIRM_REAL") == "yes",
           "set BROWSER_E2E_CONFIRM_REAL=yes only on the dedicated external test node"

    manager_url =
      System.get_env("BROWSER_E2E_MANAGER_URL", "http://127.0.0.1:8080")

    settings =
      Settings.load!(
        %{
          enabled: true,
          backend: "cloakbrowser",
          manager_url: manager_url,
          manager_token_env: "CLOAKBROWSER_MANAGER_TOKEN",
          state_dir: required_env!("BROWSER_E2E_STATE_DIR"),
          keep_profile_running: true,
          security: %{
            allowed_upload_origins: [required_env!("BROWSER_E2E_UPLOAD_ORIGIN")]
          }
        },
        manager_token: required_env!("CLOAKBROWSER_MANAGER_TOKEN")
      )

    %{
      container: required_env!("BROWSER_E2E_CLOAK_CONTAINER"),
      profile_id: required_env!("BROWSER_E2E_PROFILE_ID"),
      settings: settings
    }
  end

  test "the real host is NixOS and the dedicated CloakBrowser container is running", ctx do
    assert {:ok, os_release} = File.read("/etc/os-release")
    assert Regex.match?(~r/^ID=nixos$/m, os_release)
    assert System.find_executable("podman")

    {inspection, exit_status} =
      System.cmd(
        "podman",
        ["inspect", "--format", "{{.State.Status}} {{.Config.Image}}", ctx.container],
        stderr_to_stdout: true
      )

    assert exit_status == 0

    assert String.trim(inspection) ==
             "running localhost/cloakbrowser-manager:v0.1.5"
  end

  test "Manager v0.1.5 health and profile discovery are real and redacted", ctx do
    status = expect_ok(fn -> CloakBrowser.manager_status(ctx.settings) end, "Manager status")
    assert status["status"] == "available"
    assert is_binary(status["binary_version"])

    profiles = expect_ok(fn -> CloakBrowser.list_profiles(ctx.settings) end, "profile discovery")
    assert Enum.any?(profiles, &(&1["id"] == ctx.profile_id))

    assert Enum.all?(profiles, fn profile ->
             MapSet.disjoint?(
               profile |> recursive_keys() |> MapSet.new(),
               MapSet.new(@sensitive_profile_keys)
             )
           end)
  end

  test "dedicated profile opens a session and exposes only a loopback authenticated CDP path",
       ctx do
    profile =
      expect_ok(
        fn -> CloakBrowser.get_profile(ctx.settings, ctx.profile_id) end,
        "profile lookup"
      )

    was_running = profile["status"] == "running"
    settings = %{ctx.settings | keep_profile_running: was_running}

    session =
      expect_ok(fn -> CloakBrowser.open_session(settings, ctx.profile_id) end, "session open")

    unless was_running do
      on_exit(fn ->
        closed =
          expect_ok(fn -> CloakBrowser.close_session(settings, session) end, "session close")

        assert closed["status"] == "closed"
      end)
    end

    connection =
      expect_ok(
        fn -> CloakBrowser.connect_control_protocol(settings, session) end,
        "control-protocol connection"
      )

    assert loopback_authenticated_connection?(connection),
           "control-protocol connection did not satisfy the loopback/authentication boundary"
  end

  defp expect_ok(fun, operation) do
    case fun.() do
      {:ok, value} -> value
      {:error, _reason} -> flunk("real CloakBrowser #{operation} failed")
      _unexpected -> flunk("real CloakBrowser #{operation} returned an invalid result")
    end
  end

  defp loopback_authenticated_connection?(%{url: url, headers: headers})
       when is_binary(url) and is_list(headers) do
    uri = URI.parse(url)

    uri.scheme in ["ws", "wss"] and uri.host in ["127.0.0.1", "localhost", "::1"] and
      is_binary(uri.path) and String.starts_with?(uri.path, "/api/profiles/") and
      authenticated_headers?(headers)
  end

  defp loopback_authenticated_connection?(_connection), do: false

  defp authenticated_headers?([{"authorization", value}]) when is_binary(value),
    do: String.starts_with?(value, "Bearer ") and byte_size(value) > byte_size("Bearer ")

  defp authenticated_headers?(_headers), do: false

  defp required_env!(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _missing -> raise "missing required external E2E environment variable #{name}"
    end
  end

  defp recursive_keys(value) when is_map(value) do
    Enum.flat_map(value, fn {key, nested} -> [to_string(key) | recursive_keys(nested)] end)
  end

  defp recursive_keys(value) when is_list(value), do: Enum.flat_map(value, &recursive_keys/1)
  defp recursive_keys(_value), do: []
end
