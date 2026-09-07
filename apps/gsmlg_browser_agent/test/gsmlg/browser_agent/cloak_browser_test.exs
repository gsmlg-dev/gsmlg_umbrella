defmodule GSMLG.BrowserAgent.Backends.CloakBrowserTest do
  use ExUnit.Case, async: true

  alias GSMLG.BrowserAgent.Backends.CloakBrowser
  alias GSMLG.BrowserAgent.Backends.CloakBrowser.Transport.Finch, as: FinchTransport
  alias GSMLG.BrowserAgent.Backend.ControlConnection
  alias GSMLG.BrowserAgent.Settings

  defmodule Transport do
    @behaviour GSMLG.BrowserAgent.Backends.CloakBrowser.Transport

    @impl true
    def request(method, url, headers, body, options) do
      send(self(), {:manager_request, method, url, headers, body, options})

      case Process.get({__MODULE__, :responses}, []) do
        [response | rest] ->
          Process.put({__MODULE__, :responses}, rest)
          response

        [] ->
          {:error, :connection_failed}
      end
    end
  end

  setup do
    settings =
      Settings.load!(
        %{
          enabled: true,
          backend: "cloakbrowser",
          manager_url: "http://127.0.0.1:8080",
          manager_token_env: "IGNORED",
          state_dir: "/tmp/browser-agent-test",
          security: %{allowed_upload_origins: ["https://uploads.example.test"]}
        },
        manager_token: "manager-secret"
      )

    refute inspect(settings) =~ "manager-secret"

    %{settings: settings}
  end

  test "uses v0.1.5 health/status paths, Bearer auth, and normalized status", %{
    settings: settings
  } do
    respond([
      {:ok, %{status: 200, body: JSON.encode!(%{"status" => "ok"})}},
      {:ok,
       %{
         status: 200,
         body:
           JSON.encode!(%{
             "running_count" => 1,
             "binary_version" => "0.3.31",
             "license_tier" => "keyless",
             "profiles_total" => 2,
             "host_os" => "linux",
             "runtime_mode" => "docker",
             "viewer_mode" => "vnc"
           })
       }}
    ])

    assert {:ok,
            %{
              "status" => "available",
              "running_count" => 1,
              "binary_version" => "0.3.31",
              "profiles_total" => 2,
              "runtime_mode" => "docker"
            }} = CloakBrowser.manager_status(settings, transport: Transport)

    assert_request(:get, "/api/health", settings)
    assert_request(:get, "/api/status", settings)
  end

  test "uses profile list/get/status/launch/stop paths and removes remote-only fields", %{
    settings: settings
  } do
    sensitive = %{
      "id" => "profile-1",
      "name" => "Gemini",
      "fingerprint_seed" => 91_337,
      "proxy" => "http://user:password@example.test:8080",
      "user_data_dir" => "/data/profiles/private",
      "cdp_url" => "/api/profiles/profile-1/cdp",
      "status" => "running",
      "runtime_mode" => "docker",
      "viewer_mode" => "vnc",
      "screen_width" => 1920,
      "screen_height" => 1080,
      "locale" => "en-US",
      "timezone" => "UTC",
      "created_at" => "2026-09-04T00:00:00Z",
      "updated_at" => "2026-09-04T00:00:00Z"
    }

    respond([{:ok, %{status: 200, body: JSON.encode!([sensitive])}}])
    assert {:ok, [profile]} = CloakBrowser.list_profiles(settings, transport: Transport)
    refute JSON.encode!(profile) =~ "91337"
    refute JSON.encode!(profile) =~ "password"
    refute JSON.encode!(profile) =~ "/data/profiles"
    refute JSON.encode!(profile) =~ "/cdp"
    assert profile["screen"] == %{"width" => 1920, "height" => 1080}
    assert_request(:get, "/api/profiles", settings)

    respond([{:ok, %{status: 200, body: JSON.encode!(sensitive)}}])

    assert {:ok, %{"id" => "profile-1"}} =
             CloakBrowser.get_profile(settings, "profile-1", transport: Transport)

    assert_request(:get, "/api/profiles/profile-1", settings)

    respond([
      {:ok,
       %{
         status: 200,
         body:
           JSON.encode!(%{
             "status" => "running",
             "runtime_mode" => "docker",
             "viewer_mode" => "vnc",
             "cdp_url" => "/api/profiles/profile-1/cdp"
           })
       }}
    ])

    assert {:ok, %{"status" => "running"} = status} =
             CloakBrowser.profile_status(settings, "profile-1", transport: Transport)

    refute Map.has_key?(status, "cdp_url")
    assert_request(:get, "/api/profiles/profile-1/status", settings)

    respond([
      {:ok,
       %{
         status: 200,
         body:
           JSON.encode!(%{
             "profile_id" => "profile-1",
             "status" => "running",
             "runtime_mode" => "docker",
             "viewer_mode" => "vnc",
             "cdp_url" => "/api/profiles/profile-1/cdp"
           })
       }},
      {:ok, %{status: 200, body: JSON.encode!(%{"ok" => true})}}
    ])

    assert {:ok, %{"profile_id" => "profile-1", "status" => "running"} = launched} =
             CloakBrowser.launch_profile(settings, "profile-1", transport: Transport)

    refute Map.has_key?(launched, "cdp_url")
    assert_request(:post, "/api/profiles/profile-1/launch", settings)

    assert {:ok, %{"status" => "stopped"}} =
             CloakBrowser.stop_profile(settings, "profile-1", transport: Transport)

    assert_request(:post, "/api/profiles/profile-1/stop", settings)
  end

  test "strictly rejects malformed JSON and malformed response shapes", %{settings: settings} do
    respond([{:ok, %{status: 200, body: "not-json"}}])

    assert_manager_error(
      "manager_invalid_response",
      CloakBrowser.list_profiles(settings, transport: Transport)
    )

    respond([{:ok, %{status: 200, body: JSON.encode!(%{"id" => "not-a-list"})}}])

    assert_manager_error(
      "manager_invalid_response",
      CloakBrowser.list_profiles(settings, transport: Transport)
    )

    respond([{:ok, %{status: 200, body: JSON.encode!(%{"status" => 123})}}])

    assert_manager_error(
      "manager_invalid_response",
      CloakBrowser.profile_status(settings, "profile-1", transport: Transport)
    )

    respond([
      {:ok,
       %{
         status: 200,
         body: JSON.encode!(%{"status" => "not-ok", "token" => "health-secret"})
       }}
    ])

    result = CloakBrowser.manager_status(settings, transport: Transport)
    assert_manager_error("manager_invalid_response", result)
    refute result |> elem(1) |> JSON.encode!() =~ "health-secret"
  end

  test "opens a profile session and returns an internal authenticated page CDP connection", %{
    settings: settings
  } do
    callbacks = GSMLG.BrowserAgent.Backend.behaviour_info(:callbacks)

    for callback <- [
          manager_status: 2,
          list_profiles: 2,
          get_profile: 3,
          launch_profile: 3,
          stop_profile: 3,
          open_session: 3,
          close_session: 3,
          connect_control_protocol: 3
        ] do
      assert callback in callbacks
    end

    stopped_profile = %{
      "id" => "profile-1",
      "name" => "Gemini",
      "status" => "stopped",
      "screen_width" => 1920,
      "screen_height" => 1080,
      "locale" => "en-US",
      "timezone" => "UTC",
      "runtime_mode" => "docker",
      "viewer_mode" => "vnc"
    }

    respond([
      {:ok, %{status: 200, body: JSON.encode!([stopped_profile])}},
      {:ok,
       %{
         status: 200,
         body:
           JSON.encode!(%{
             "profile_id" => "profile-1",
             "status" => "running",
             "runtime_mode" => "docker",
             "viewer_mode" => "vnc",
             "cdp_url" => "/api/profiles/profile-1/cdp"
           })
       }}
    ])

    assert {:ok, %{"profile_id" => "profile-1", "status" => "running"} = session} =
             CloakBrowser.open_session(settings, "profile-1", transport: Transport)

    assert_request(:get, "/api/profiles", settings)
    assert_request(:post, "/api/profiles/profile-1/launch", settings)

    respond([
      {:ok,
       %{
         status: 200,
         body:
           JSON.encode!([
             %{
               "id" => "page-1",
               "type" => "page",
               "url" => "https://gemini.google.com/app",
               "webSocketDebuggerUrl" =>
                 "ws://127.0.0.1:8080/api/profiles/profile-1/cdp/devtools/page/page-1"
             }
           ])
       }}
    ])

    assert {:ok,
            %ControlConnection{
              url: "ws://127.0.0.1:8080/api/profiles/profile-1/cdp/devtools/page/page-1",
              headers: [{"authorization", "Bearer manager-secret"}]
            } = connection} =
             CloakBrowser.connect_control_protocol(settings, session, transport: Transport)

    refute inspect(connection) =~ "manager-secret"
    refute inspect(connection) =~ "/cdp"

    assert_request(:get, "/api/profiles/profile-1/cdp/json/list", settings)

    assert {:ok, %{"profile_id" => "profile-1", "status" => "closed"}} =
             CloakBrowser.close_session(settings, session, transport: Transport)
  end

  test "rejects cross-host CDP URLs and blocks session launch while another profile runs", %{
    settings: settings
  } do
    other = %{
      "id" => "other-profile",
      "name" => "Other",
      "status" => "running",
      "screen_width" => 1920,
      "screen_height" => 1080,
      "runtime_mode" => "docker",
      "viewer_mode" => "vnc"
    }

    target = %{other | "id" => "profile-1", "name" => "Target", "status" => "stopped"}
    respond([{:ok, %{status: 200, body: JSON.encode!([target, other])}}])

    assert_manager_error(
      "profile_busy",
      CloakBrowser.open_session(settings, "profile-1", transport: Transport)
    )

    respond([
      {:ok,
       %{
         status: 200,
         body:
           JSON.encode!([
             %{
               "id" => "page-1",
               "type" => "page",
               "webSocketDebuggerUrl" => "ws://evil.example/cdp"
             }
           ])
       }}
    ])

    assert_manager_error(
      "manager_invalid_response",
      CloakBrowser.connect_control_protocol(
        settings,
        %{"profile_id" => "profile-1"},
        transport: Transport
      )
    )
  end

  test "malformed CDP target entries return a bounded Manager error", %{settings: settings} do
    respond([{:ok, %{status: 200, body: JSON.encode!([nil, "page", 42])}}])

    assert_manager_error(
      "manager_invalid_response",
      CloakBrowser.connect_control_protocol(
        settings,
        %{"profile_id" => "profile-1"},
        transport: Transport
      )
    )
  end

  test "maps timeout, authorization, absence, conflict, and server failures to stable codes", %{
    settings: settings
  } do
    for {response, expected} <- [
          {{:error, :timeout}, "manager_timeout"},
          {{:ok, %{status: 401, body: "manager-secret"}}, "manager_unauthorized"},
          {{:ok, %{status: 402, body: "private-license-body"}}, "manager_license_denied"},
          {{:ok, %{status: 403, body: "private-license-body"}}, "manager_license_denied"},
          {{:ok, %{status: 404, body: "private-path"}}, "profile_not_found"},
          {{:ok, %{status: 409, body: "private-body"}}, "profile_busy"},
          {{:ok, %{status: 503, body: "private-body"}}, "manager_unavailable"}
        ] do
      respond([response])

      assert_manager_error(
        expected,
        CloakBrowser.get_profile(settings, "profile-1", transport: Transport)
      )
    end
  end

  test "rejects profile identifiers that could alter the Manager request target", %{
    settings: settings
  } do
    assert_manager_error(
      "invalid_profile_id",
      CloakBrowser.get_profile(settings, "profile/../../status?token=secret",
        transport: Transport
      )
    )

    refute_receive {:manager_request, _, _, _, _, _}
  end

  test "Finch streaming reducer rejects over-limit bodies without retaining the overflow" do
    initial = FinchTransport.initial_accumulator()
    assert {:cont, state} = FinchTransport.reduce_response({:status, 200}, initial, 5)
    assert {:cont, state} = FinchTransport.reduce_response({:data, "12345"}, state, 5)

    assert {:halt, %{error: :body_too_large, body_size: 5}} =
             FinchTransport.reduce_response({:data, "sensitive-overflow"}, state, 5)
  end

  test "Finch transport returns a successful bounded response when no reducer error exists" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    finch_name = __MODULE__.SuccessFinch
    {:ok, _finch} = Finch.start_link(name: finch_name)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-length: 11\r\nconnection: close\r\n\r\n{\"ok\":true}"
          )

        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
    end)

    assert {:ok, %{status: 200, body: "{\"ok\":true}"}} =
             FinchTransport.request(
               :get,
               "http://127.0.0.1:#{port}/health",
               [],
               "",
               finch_name: finch_name,
               connect_timeout: 500,
               receive_timeout: 500,
               max_body_bytes: 1_024
             )

    assert :ok = Task.await(server)
  end

  defp respond(responses), do: Process.put({Transport, :responses}, responses)

  defp assert_request(method, path, settings) do
    assert_receive {:manager_request, ^method, url, headers, "", options}
    assert URI.parse(url).path == path
    assert {"authorization", "Bearer manager-secret"} in headers
    assert options[:max_body_bytes] == settings.max_response_bytes
    assert options[:receive_timeout] == settings.request_timeout_ms
  end

  defp assert_manager_error(code, result) do
    assert {:error, %{class: "manager", code: ^code, details: %{}}} = result
  end
end
