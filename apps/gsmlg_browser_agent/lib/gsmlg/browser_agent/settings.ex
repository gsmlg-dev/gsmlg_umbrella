defmodule GSMLG.BrowserAgent.Settings do
  @moduledoc "Runtime settings for the remote Browser Agent."

  @action_result_overhead_bytes 65_536

  @enforce_keys [:manager_url, :manager_token, :state_dir]
  defstruct enabled: false,
            backend: "cloakbrowser",
            manager_url: nil,
            manager_token_env: "CLOAKBROWSER_MANAGER_TOKEN",
            manager_token: nil,
            state_dir: nil,
            default_profile_id: nil,
            max_concurrent_sessions: 1,
            max_concurrent_workflows: 1,
            keep_profile_running: true,
            manager_connect_timeout_ms: 2_000,
            request_timeout_ms: 5_000,
            max_response_bytes: 1_048_576,
            max_observation_bytes: 1_048_576,
            max_artifact_bytes: 104_857_600,
            inline_artifact_max_bytes: 131_072,
            monitor_interval_ms: 15_000,
            lease_ttl_ms: 7_200_000,
            journal_terminal_max_records: 10_000,
            journal_terminal_max_age_ms: 2_592_000_000,
            journal_terminal_max_bytes: 67_108_864,
            journal_recovery_scan_max_records: 10_000,
            allow_css_locator: false,
            allowed_origins: [],
            allowed_upload_origins: []

  @type t :: %__MODULE__{
          enabled: boolean(),
          backend: String.t(),
          manager_url: String.t(),
          manager_token_env: String.t(),
          manager_token: String.t() | nil,
          state_dir: String.t(),
          default_profile_id: String.t() | nil,
          max_concurrent_sessions: pos_integer(),
          max_concurrent_workflows: pos_integer(),
          keep_profile_running: boolean(),
          manager_connect_timeout_ms: pos_integer(),
          request_timeout_ms: pos_integer(),
          max_response_bytes: pos_integer(),
          max_observation_bytes: pos_integer(),
          max_artifact_bytes: pos_integer(),
          inline_artifact_max_bytes: pos_integer(),
          monitor_interval_ms: pos_integer(),
          lease_ttl_ms: pos_integer(),
          journal_terminal_max_records: pos_integer(),
          journal_terminal_max_age_ms: pos_integer(),
          journal_terminal_max_bytes: pos_integer(),
          journal_recovery_scan_max_records: pos_integer(),
          allow_css_locator: boolean(),
          allowed_origins: [String.t()],
          allowed_upload_origins: [String.t()]
        }

  @defaults %{
    enabled: false,
    backend: "cloakbrowser",
    manager_url: "http://127.0.0.1:8080",
    manager_token_env: "CLOAKBROWSER_MANAGER_TOKEN",
    state_dir: "/var/lib/gsmlg/browser-agent",
    default_profile_id: nil,
    max_concurrent_sessions: 1,
    max_concurrent_workflows: 1,
    keep_profile_running: true,
    manager_connect_timeout_ms: 2_000,
    request_timeout_ms: 5_000,
    max_response_bytes: 1_048_576,
    max_observation_bytes: 1_048_576,
    max_artifact_bytes: 104_857_600,
    inline_artifact_max_bytes: 131_072,
    monitor_interval_ms: 15_000,
    lease_ttl_ms: 7_200_000,
    journal_terminal_max_records: 10_000,
    journal_terminal_max_age_ms: 2_592_000_000,
    journal_terminal_max_bytes: 67_108_864,
    journal_recovery_scan_max_records: 10_000,
    security: %{
      allowed_origins: [
        "https://gemini.google.com",
        "https://accounts.google.com",
        "https://www.youtube.com",
        "https://youtube.com",
        "https://youtu.be"
      ],
      allowed_upload_origins: [],
      allow_css_locator: false
    }
  }

  @spec load(map() | keyword(), keyword()) :: {:ok, t()} | {:error, atom()}
  def load(config \\ Application.get_env(:gsmlg_browser_agent, :settings, %{}), opts \\ []) do
    config = config |> normalize_map() |> merge_defaults()
    enabled = config.enabled == true
    token = manager_token(config, opts)

    with :ok <- validate_backend(config.backend),
         :ok <- validate_manager_url(config.manager_url, enabled),
         :ok <- validate_string(config.state_dir, :state_dir_missing),
         :ok <- validate_string(config.manager_token_env, :manager_token_env_missing),
         :ok <- validate_token(token, enabled),
         :ok <- validate_positive_settings(config),
         :ok <- validate_size_limits(config),
         :ok <- validate_security(config.security, enabled),
         :ok <- validate_journal_result_budget(config) do
      {:ok,
       struct!(__MODULE__,
         enabled: enabled,
         backend: config.backend,
         manager_url: String.trim_trailing(config.manager_url, "/"),
         manager_token_env: config.manager_token_env,
         manager_token: token,
         state_dir: config.state_dir,
         default_profile_id: config.default_profile_id,
         max_concurrent_sessions: config.max_concurrent_sessions,
         max_concurrent_workflows: config.max_concurrent_workflows,
         keep_profile_running: config.keep_profile_running,
         manager_connect_timeout_ms: config.manager_connect_timeout_ms,
         request_timeout_ms: config.request_timeout_ms,
         max_response_bytes: config.max_response_bytes,
         max_observation_bytes: config.max_observation_bytes,
         max_artifact_bytes: config.max_artifact_bytes,
         inline_artifact_max_bytes: config.inline_artifact_max_bytes,
         monitor_interval_ms: config.monitor_interval_ms,
         lease_ttl_ms: config.lease_ttl_ms,
         journal_terminal_max_records: config.journal_terminal_max_records,
         journal_terminal_max_age_ms: config.journal_terminal_max_age_ms,
         journal_terminal_max_bytes: config.journal_terminal_max_bytes,
         journal_recovery_scan_max_records: config.journal_recovery_scan_max_records,
         allow_css_locator: get_in(config, [:security, :allow_css_locator]) == true,
         allowed_origins: get_in(config, [:security, :allowed_origins]) || [],
         allowed_upload_origins:
           if(enabled,
             do: get_in(config, [:security, :allowed_upload_origins]) || [],
             else: []
           )
       )}
    end
  end

  @spec load!(map() | keyword(), keyword()) :: t()
  def load!(config \\ Application.get_env(:gsmlg_browser_agent, :settings, %{}), opts \\ []) do
    case load(config, opts) do
      {:ok, settings} -> settings
      {:error, reason} -> raise ArgumentError, "invalid Browser Agent configuration: #{reason}"
    end
  end

  defp normalize_map(config) when is_map(config), do: normalize_security(config)
  defp normalize_map(config) when is_list(config), do: config |> Map.new() |> normalize_security()

  defp normalize_security(config) do
    security = config |> Map.get(:security, %{}) |> normalize_nested_map()
    Map.put(config, :security, security)
  end

  defp normalize_nested_map(map) when is_map(map), do: map
  defp normalize_nested_map(list) when is_list(list), do: Map.new(list)
  defp normalize_nested_map(_invalid), do: %{}

  defp merge_defaults(config) do
    security = Map.merge(@defaults.security, Map.get(config, :security, %{}))
    @defaults |> Map.merge(config) |> Map.put(:security, security)
  end

  defp manager_token(config, opts) do
    case Keyword.get(opts, :manager_token) do
      token when is_binary(token) -> token
      _ -> Keyword.get(opts, :env, &System.get_env/1).(config.manager_token_env)
    end
  end

  defp validate_backend("cloakbrowser"), do: :ok
  defp validate_backend(_backend), do: {:error, :unsupported_backend}

  defp validate_manager_url(url, enabled) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "http", host: host, userinfo: nil, query: nil, fragment: nil}
      when host in ["127.0.0.1", "localhost", "::1"] ->
        :ok

      _invalid when enabled ->
        {:error, :manager_url_not_loopback}

      _invalid ->
        :ok
    end
  end

  defp validate_manager_url(_url, true), do: {:error, :manager_url_not_loopback}
  defp validate_manager_url(_url, false), do: {:error, :manager_url_invalid}

  defp validate_string(value, _reason) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp validate_string(_value, reason), do: {:error, reason}

  defp validate_token(token, true) when not is_binary(token) or token == "",
    do: {:error, :manager_token_missing}

  defp validate_token(_token, _enabled), do: :ok

  defp validate_positive_settings(config) do
    keys = [
      :max_concurrent_sessions,
      :max_concurrent_workflows,
      :manager_connect_timeout_ms,
      :request_timeout_ms,
      :max_response_bytes,
      :max_observation_bytes,
      :max_artifact_bytes,
      :inline_artifact_max_bytes,
      :monitor_interval_ms,
      :lease_ttl_ms,
      :journal_terminal_max_records,
      :journal_terminal_max_age_ms,
      :journal_terminal_max_bytes,
      :journal_recovery_scan_max_records
    ]

    if Enum.all?(keys, &(is_integer(config[&1]) and config[&1] > 0)),
      do: :ok,
      else: {:error, :invalid_positive_setting}
  end

  defp validate_size_limits(config) do
    if config.max_observation_bytes <= 1_048_576 and
         config.max_artifact_bytes <= 104_857_600 and
         config.inline_artifact_max_bytes <= 131_072 and
         config.inline_artifact_max_bytes <= config.max_artifact_bytes do
      :ok
    else
      {:error, :invalid_size_limit}
    end
  end

  defp validate_security(security, true) when is_map(security) do
    origins = Map.get(security, :allowed_origins)
    upload_origins = Map.get(security, :allowed_upload_origins)

    cond do
      not valid_origins?(origins) -> {:error, :invalid_allowed_origins}
      not valid_origins?(upload_origins) -> {:error, :invalid_allowed_upload_origins}
      true -> :ok
    end
  end

  defp validate_security(_security, false), do: :ok
  defp validate_security(_security, true), do: {:error, :invalid_allowed_origins}

  defp valid_origins?(origins) do
    is_list(origins) and origins != [] and origins == Enum.uniq(origins) and
      Enum.all?(origins, fn origin ->
        match?(
          %URI{scheme: "https", userinfo: nil, path: path, query: nil, fragment: nil}
          when path in [nil, ""],
          URI.parse(origin)
        ) and
          match?({:ok, ^origin}, GSMLG.BrowserAgent.OriginPolicy.origin(origin))
      end)
  end

  defp validate_journal_result_budget(config) do
    required_bytes = config.max_response_bytes * 2 + @action_result_overhead_bytes

    if config.journal_terminal_max_bytes >= required_bytes,
      do: :ok,
      else: {:error, :journal_result_budget_too_small}
  end
end

defimpl Inspect, for: GSMLG.BrowserAgent.Settings do
  import Inspect.Algebra

  def inspect(settings, opts) do
    settings
    |> Map.from_struct()
    |> Map.put(:manager_token, "[REDACTED]")
    |> to_doc(opts)
  end
end
