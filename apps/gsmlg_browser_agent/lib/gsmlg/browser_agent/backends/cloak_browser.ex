defmodule GSMLG.BrowserAgent.Backends.CloakBrowser do
  @moduledoc "Strict, redacting adapter for CloakBrowser Manager v0.1.5."

  @behaviour GSMLG.BrowserAgent.Backend

  alias GSMLG.BrowserAgent.Backends.CloakBrowser.Transport.Finch, as: FinchTransport
  alias GSMLG.BrowserAgent.Backend.ControlConnection
  alias GSMLG.BrowserAgent.Settings

  @profile_statuses ["running", "stopped"]

  @impl true
  def manager_status(%Settings{} = settings, opts \\ []) do
    with {:ok, %{"status" => "ok"}} <- request(settings, :get, "/api/health", opts),
         {:ok, payload} <- request(settings, :get, "/api/status", opts),
         {:ok, status} <- normalize_manager_status(payload) do
      {:ok, status}
    else
      {:ok, _invalid} -> error("manager_invalid_response", false)
      {:error, _error} = error -> error
    end
  end

  @impl true
  def list_profiles(%Settings{} = settings, opts \\ []) do
    with {:ok, profiles} when is_list(profiles) <- request(settings, :get, "/api/profiles", opts),
         {:ok, normalized} <- normalize_profiles(profiles) do
      {:ok, normalized}
    else
      {:ok, _invalid} -> error("manager_invalid_response", false)
      {:error, _error} = error -> error
    end
  end

  @impl true
  def get_profile(%Settings{} = settings, profile_id, opts \\ []) do
    with :ok <- validate_profile_id(profile_id),
         {:ok, profile} <- request(settings, :get, profile_path(profile_id), opts),
         {:ok, normalized} <- normalize_profile(profile) do
      {:ok, normalized}
    end
  end

  @impl true
  def profile_status(%Settings{} = settings, profile_id, opts \\ []) do
    with :ok <- validate_profile_id(profile_id),
         {:ok, status} <- request(settings, :get, profile_path(profile_id, "/status"), opts),
         {:ok, normalized} <- normalize_profile_status(status) do
      {:ok, normalized}
    end
  end

  @impl true
  def launch_profile(%Settings{} = settings, profile_id, opts \\ []) do
    with :ok <- validate_profile_id(profile_id),
         {:ok, launched} <- request(settings, :post, profile_path(profile_id, "/launch"), opts),
         {:ok, normalized} <- normalize_launch(launched, profile_id) do
      {:ok, normalized}
    end
  end

  @impl true
  def stop_profile(%Settings{} = settings, profile_id, opts \\ []) do
    with :ok <- validate_profile_id(profile_id),
         {:ok, %{"ok" => true}} <-
           request(settings, :post, profile_path(profile_id, "/stop"), opts) do
      {:ok, %{"profile_id" => profile_id, "status" => "stopped"}}
    else
      {:ok, _invalid} -> error("manager_invalid_response", false)
      {:error, _error} = error -> error
    end
  end

  @impl true
  def open_session(%Settings{} = settings, profile_id, opts \\ []) do
    with :ok <- validate_profile_id(profile_id),
         {:ok, profiles} <- list_profiles(settings, opts),
         {:ok, profile} <- admit_session_profile(profiles, profile_id),
         {:ok, opened} <- ensure_profile_running(settings, profile, opts) do
      {:ok,
       opened
       |> Map.take(["profile_id", "status", "runtime_mode", "viewer_mode"])
       |> Map.put("profile_id", profile_id)}
    end
  end

  @impl true
  def close_session(settings, session, opts \\ [])

  def close_session(%Settings{} = settings, %{"profile_id" => profile_id}, opts) do
    with :ok <- validate_profile_id(profile_id),
         :ok <- maybe_stop_profile(settings, profile_id, opts) do
      {:ok, %{"profile_id" => profile_id, "status" => "closed"}}
    end
  end

  def close_session(%Settings{}, _session, _opts), do: error("manager_invalid_request", false)

  @impl true
  def connect_control_protocol(settings, session, opts \\ [])

  def connect_control_protocol(
        %Settings{} = settings,
        %{"profile_id" => profile_id},
        opts
      ) do
    with :ok <- validate_profile_id(profile_id),
         {:ok, targets} when is_list(targets) <-
           request(settings, :get, profile_path(profile_id, "/cdp/json/list"), opts),
         {:ok, url} <- page_websocket_url(targets, settings, profile_id) do
      {:ok,
       %ControlConnection{
         url: url,
         headers: [{"authorization", "Bearer #{settings.manager_token}"}]
       }}
    else
      {:error, _error} = error -> error
      _invalid -> error("manager_invalid_response", false)
    end
  end

  def connect_control_protocol(%Settings{}, _session, _opts),
    do: error("manager_invalid_request", false)

  defp request(settings, method, path, opts) do
    transport = Keyword.get(opts, :transport, FinchTransport)
    headers = [{"authorization", "Bearer #{settings.manager_token}"}]

    options = [
      finch_name: Keyword.get(opts, :finch_name, GSMLG.BrowserAgent.Finch),
      connect_timeout: settings.manager_connect_timeout_ms,
      receive_timeout: settings.request_timeout_ms,
      max_body_bytes: settings.max_response_bytes
    ]

    case transport.request(method, settings.manager_url <> path, headers, "", options) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> decode_json(body)
      {:ok, %{status: status}} -> map_http_error(status)
      {:error, reason} -> map_transport_error(reason)
    end
  rescue
    _exception -> error("manager_unavailable", true)
  catch
    _kind, _reason -> error("manager_unavailable", true)
  end

  defp decode_json(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> error("manager_invalid_response", false)
    end
  end

  defp normalize_manager_status(payload) when is_map(payload) do
    with {:ok, running_count} <- required_nonnegative_integer(payload, "running_count"),
         {:ok, binary_version} <- required_string(payload, "binary_version"),
         {:ok, license_tier} <- required_string(payload, "license_tier"),
         {:ok, profiles_total} <- required_nonnegative_integer(payload, "profiles_total"),
         {:ok, host_os} <- required_string(payload, "host_os"),
         {:ok, runtime_mode} <- required_string(payload, "runtime_mode"),
         {:ok, viewer_mode} <- required_string(payload, "viewer_mode") do
      {:ok,
       %{
         "status" => "available",
         "running_count" => running_count,
         "binary_version" => binary_version,
         "license_tier" => license_tier,
         "profiles_total" => profiles_total,
         "host_os" => host_os,
         "runtime_mode" => runtime_mode,
         "viewer_mode" => viewer_mode
       }}
    end
  end

  defp normalize_manager_status(_invalid), do: error("manager_invalid_response", false)

  defp normalize_profiles(profiles) do
    Enum.reduce_while(profiles, {:ok, []}, fn profile, {:ok, normalized} ->
      case normalize_profile(profile) do
        {:ok, safe_profile} -> {:cont, {:ok, [safe_profile | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_profile(profile) when is_map(profile) do
    with {:ok, id} <- required_string(profile, "id"),
         {:ok, name} <- required_string(profile, "name"),
         {:ok, status} <- required_enum(profile, "status", @profile_statuses),
         {:ok, width} <- required_positive_integer(profile, "screen_width"),
         {:ok, height} <- required_positive_integer(profile, "screen_height"),
         {:ok, locale} <- optional_string(profile, "locale"),
         {:ok, timezone} <- optional_string(profile, "timezone"),
         {:ok, runtime_mode} <- required_string(profile, "runtime_mode"),
         {:ok, viewer_mode} <- required_string(profile, "viewer_mode") do
      {:ok,
       %{
         "id" => id,
         "name" => name,
         "status" => status,
         "screen" => %{"width" => width, "height" => height},
         "locale" => locale,
         "timezone" => timezone,
         "runtime_mode" => runtime_mode,
         "viewer_mode" => viewer_mode
       }}
    end
  end

  defp normalize_profile(_invalid), do: error("manager_invalid_response", false)

  defp normalize_profile_status(status) when is_map(status) do
    with {:ok, state} <- required_enum(status, "status", @profile_statuses),
         {:ok, runtime_mode} <- required_string(status, "runtime_mode"),
         {:ok, viewer_mode} <- required_string(status, "viewer_mode") do
      {:ok,
       %{
         "status" => state,
         "runtime_mode" => runtime_mode,
         "viewer_mode" => viewer_mode
       }}
    end
  end

  defp normalize_profile_status(_invalid), do: error("manager_invalid_response", false)

  defp normalize_launch(launch, expected_profile_id) when is_map(launch) do
    with {:ok, ^expected_profile_id} <- required_string(launch, "profile_id"),
         {:ok, "running"} <- required_enum(launch, "status", ["running"]),
         {:ok, runtime_mode} <- required_string(launch, "runtime_mode"),
         {:ok, viewer_mode} <- required_string(launch, "viewer_mode") do
      {:ok,
       %{
         "profile_id" => expected_profile_id,
         "status" => "running",
         "runtime_mode" => runtime_mode,
         "viewer_mode" => viewer_mode
       }}
    else
      _invalid -> error("manager_invalid_response", false)
    end
  end

  defp normalize_launch(_invalid, _profile_id), do: error("manager_invalid_response", false)

  defp required_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _invalid -> error("manager_invalid_response", false)
    end
  end

  defp optional_string(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _invalid -> error("manager_invalid_response", false)
    end
  end

  defp required_nonnegative_integer(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _invalid -> error("manager_invalid_response", false)
    end
  end

  defp required_positive_integer(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _invalid -> error("manager_invalid_response", false)
    end
  end

  defp required_enum(map, key, allowed) do
    with {:ok, value} <- required_string(map, key),
         true <- value in allowed do
      {:ok, value}
    else
      _invalid -> error("manager_invalid_response", false)
    end
  end

  defp validate_profile_id(profile_id) when is_binary(profile_id) do
    if byte_size(profile_id) in 1..200 and
         Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, profile_id),
       do: :ok,
       else: error("invalid_profile_id", false)
  end

  defp validate_profile_id(_profile_id), do: error("invalid_profile_id", false)

  defp profile_path(profile_id, suffix \\ "") do
    encoded = URI.encode(profile_id, &URI.char_unreserved?/1)
    "/api/profiles/#{encoded}#{suffix}"
  end

  defp map_http_error(401), do: error("manager_unauthorized", false)

  defp map_http_error(status) when status in [402, 403],
    do: error("manager_license_denied", false)

  defp map_http_error(404), do: error("profile_not_found", false)
  defp map_http_error(409), do: error("profile_busy", true)
  defp map_http_error(400), do: error("manager_invalid_request", false)
  defp map_http_error(status) when status >= 500, do: error("manager_unavailable", true)
  defp map_http_error(_status), do: error("manager_request_failed", false)

  defp map_transport_error(:timeout), do: error("manager_timeout", true)
  defp map_transport_error(:body_too_large), do: error("manager_response_too_large", false)
  defp map_transport_error(:headers_too_large), do: error("manager_response_too_large", false)
  defp map_transport_error(_reason), do: error("manager_unavailable", true)

  defp admit_session_profile(profiles, profile_id) do
    target = Enum.find(profiles, &(&1["id"] == profile_id))

    cond do
      is_nil(target) ->
        error("profile_not_found", false)

      Enum.any?(profiles, &(&1["id"] != profile_id and &1["status"] == "running")) ->
        error("profile_busy", true)

      true ->
        {:ok, target}
    end
  end

  defp ensure_profile_running(_settings, %{"status" => "running"} = profile, _opts) do
    {:ok,
     profile
     |> Map.take(["runtime_mode", "viewer_mode"])
     |> Map.put("profile_id", profile["id"])
     |> Map.put("status", "running")}
  end

  defp ensure_profile_running(settings, %{"status" => "stopped", "id" => profile_id}, opts),
    do: launch_profile(settings, profile_id, opts)

  defp ensure_profile_running(_settings, _profile, _opts),
    do: error("manager_invalid_response", false)

  defp maybe_stop_profile(%Settings{keep_profile_running: true}, _profile_id, _opts), do: :ok

  defp maybe_stop_profile(%Settings{} = settings, profile_id, opts) do
    case stop_profile(settings, profile_id, opts) do
      {:ok, _status} -> :ok
      {:error, _error} = error -> error
    end
  end

  defp page_websocket_url(targets, settings, profile_id) do
    with true <- Enum.all?(targets, &is_map/1),
         %{"webSocketDebuggerUrl" => url} when is_binary(url) <-
           Enum.find(targets, &(&1["type"] == "page")),
         :ok <- validate_control_url(url, settings, profile_id) do
      {:ok, url}
    else
      _invalid -> error("manager_invalid_response", false)
    end
  end

  defp validate_control_url(url, settings, profile_id) do
    manager = URI.parse(settings.manager_url)
    control = URI.parse(url)
    expected_scheme = if manager.scheme == "https", do: "wss", else: "ws"
    expected_path = profile_path(profile_id, "/cdp/devtools/")

    if control.scheme == expected_scheme and control.host == manager.host and
         effective_port(control) == effective_port(manager) and is_nil(control.userinfo) and
         is_nil(control.query) and is_nil(control.fragment) and
         is_binary(control.path) and String.starts_with?(control.path, expected_path) and
         byte_size(control.path) > byte_size(expected_path),
       do: :ok,
       else: error("manager_invalid_response", false)
  end

  defp effective_port(%URI{port: port}) when is_integer(port), do: port
  defp effective_port(%URI{scheme: scheme}), do: URI.default_port(scheme)

  defp error(code, retryable) do
    {:error,
     %{
       class: "manager",
       code: code,
       message: code |> String.replace("_", " ") |> String.capitalize(),
       retryable: retryable,
       human_action: "none",
       details: %{}
     }}
  end
end
