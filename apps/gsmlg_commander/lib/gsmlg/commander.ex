defmodule GSMLG.Commander do
  @moduledoc """
  # GSMLG.Commander - Distributed Command Execution System

  Commander provides secure, managed remote shell access through a reverse-connection
  architecture. Remote agents initiate outbound WebSocket connections to a central
  control server, enabling terminal access to machines behind firewalls without
  inbound port exposure.

  ## Architecture

  ```
  ┌─────────────────────────────────────────────────────────────────────────┐
  │                         Commander Ecosystem                              │
  │                                                                          │
  │   Remote Machine                          Control Server                 │
  │   ┌──────────────┐                       ┌──────────────────────┐       │
  │   │   Agent      │ ──── WebSocket ────►  │   Commander Server   │       │
  │   │              │      (outbound)        │                      │       │
  │   │  ┌────────┐  │                       │  ┌────────────────┐  │       │
  │   │  │  PTY   │  │ ◄─── commands ──────  │  │    Session     │  │       │
  │   │  │ (bash) │  │                       │  │   (GenServer)  │  │       │
  │   │  └────────┘  │ ────  output  ─────►  │  └────────────────┘  │       │
  │   └──────────────┘                       │           │          │       │
  │                                          │           ▼          │       │
  │                                          │  ┌────────────────┐  │       │
  │   Operator Browser                       │  │    Manager     │  │       │
  │   ┌──────────────┐                       │  └────────────────┘  │       │
  │   │   xterm.js   │ ◄─── WebSocket ────►  │                      │       │
  │   └──────────────┘      (standard)       └──────────────────────┘       │
  │                                                                          │
  └─────────────────────────────────────────────────────────────────────────┘
  ```

  ## Modes of Operation

  1. **Agent mode** (`start: true`) - Runs on remote machines to be managed
  2. **Server mode** (`server: true`) - Runs on the management server

  ## Components

  ### Server-Side
  - `GSMLG.Commander.Session` - Server-side session managing agent connection
  - `GSMLG.Commander.SessionRegistry` - Registry with metadata support
  - `GSMLG.Commander.SessionSupervisor` - DynamicSupervisor for sessions
  - `GSMLG.Commander.Manager` - Orchestration and health monitoring
  - `GSMLG.Commander.TokenManager` - Agent authentication tokens
  - `GSMLG.Commander.Policy` - Authorization rules
  - `GSMLG.Commander.Protocol` - Wire protocol definitions

  ### Agent-Side
  - `GSMLG.Commander.Agent.Config` - Agent configuration from TOML
  - `GSMLG.Commander.SessionManager` - Local PTY session manager
  - `GSMLG.Commander.Terminal` - PTY terminal channel

  ## Configuration

  ```elixir
  config :gsmlg_commander, GSMLG.Commander,
    start: false,           # Enable agent mode
    server: true,           # Enable server mode
    features: [:pty],
    platform_url: "wss://...",
    platform_key: "..."

  config :gsmlg_commander,
    server: [
      agent_endpoint: "/agent/connect",
      operator_endpoint: "/operator/terminal",
      heartbeat_interval_ms: 30_000,
      heartbeat_timeout_ms: 90_000,
      reconnect_grace_period_ms: 120_000,
      max_agents: 10_000,
      max_ptys_per_agent: 10
    ],
    auth: [
      agent_auth_type: :token,
      operator_auth_type: :jwt
    ],
    policy: [
      default_access: :none,
      enable_tag_matching: true
    ]
  ```
  """

  use Application

  require GSMLG.Telemetry

  @supported_features [:pty]
  @default_max_in_flight_rpcs 2

  @impl true
  def start(_type, _args) do
    config = Application.get_env(:gsmlg_commander, GSMLG.Commander, [])
    start_agent = Keyword.get(config, :start, false)
    start_server = Keyword.get(config, :server, false)

    if start_agent, do: configure_socket_telemetry()

    children = build_children(start_agent, start_server, config)

    opts = [strategy: :one_for_one, name: __MODULE__]

    GSMLG.Telemetry.info("Starting Commander application",
      start_agent: start_agent,
      start_server: start_server
    )

    Supervisor.start_link(children, opts)
  end

  @doc """
  Return socket connection options for agent mode
  """
  @spec socket_opts(keyword()) :: keyword()
  def socket_opts(config \\ config()) do
    url = Keyword.get(config, :platform_url)
    validate_agent_config!(config)

    transport_opts =
      case GSMLG.Commander.TLS.transport_opts(url, Keyword.get(config, :tls, [])) do
        {:ok, options} ->
          options

        {:error, reason} ->
          raise ArgumentError, "invalid Commander TLS configuration: #{inspect(reason)}"
      end

    auth_provider = fn -> fresh_auth_params(config) end

    [
      url: url,
      params: %{},
      transport: GSMLG.Commander.Transport,
      transport_opts: [commander_auth_provider: auth_provider] ++ transport_opts
    ]
  end

  @doc false
  def fresh_auth_params(config) do
    priv_key = Keyword.fetch!(config, :platform_key)
    name = Keyword.fetch!(config, :name)
    credential_id = Keyword.fetch!(config, :credential_id)
    sign_at = System.system_time(:second)
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    signature =
      credential_id
      |> signature_payload(name, sign_at, nonce)
      |> then(&:crypto.mac(:hmac, :sha256, priv_key, &1))
      |> Base.encode16(case: :lower)

    %{
      "signature" => signature,
      "name" => name,
      "credential_id" => credential_id,
      "sign_at" => Integer.to_string(sign_at),
      "nonce" => nonce
    }
  end

  defp validate_agent_config!(config) do
    for key <- [:platform_url, :platform_key, :name, :credential_id] do
      case Keyword.get(config, key) do
        value when is_binary(value) and byte_size(value) > 0 -> :ok
        _ -> raise ArgumentError, "Commander #{key} is required in agent mode"
      end
    end

    case URI.parse(Keyword.fetch!(config, :platform_url)) do
      %URI{scheme: scheme, host: host}
      when scheme in ["ws", "wss"] and is_binary(host) and byte_size(host) > 0 ->
        :ok

      _invalid ->
        raise ArgumentError, "Commander platform_url must be a valid ws:// or wss:// URL"
    end
  end

  @doc false
  def signature_payload(credential_id, name, sign_at, nonce) do
    "v1\n#{credential_id}\n#{name}\n#{sign_at}\n#{nonce}"
  end

  @doc "Disables dependency telemetry that currently exposes transport options and payloads."
  @spec configure_socket_telemetry() :: :ok
  def configure_socket_telemetry do
    # WORKAROUND(upstream): gsmlg-dev/phoenix_socket_client#105
    # The dependency currently emits complete TLS options and message payloads.
    Phoenix.SocketClient.Telemetry.detach_debug_handler()
    Phoenix.SocketClient.Telemetry.update_config(%{enabled: false})
  end

  @doc """
  Returns whether the Commander is running in agent mode.
  """
  @spec agent_mode?() :: boolean()
  def agent_mode? do
    config = Application.get_env(:gsmlg_commander, GSMLG.Commander, [])
    Keyword.get(config, :start, false)
  end

  @doc """
  Returns whether the Commander is running in server mode.
  """
  @spec server_mode?() :: boolean()
  def server_mode? do
    config = Application.get_env(:gsmlg_commander, GSMLG.Commander, [])
    Keyword.get(config, :server, false)
  end

  @doc """
  Gets the current Commander configuration.
  """
  @spec config() :: keyword()
  def config do
    Application.get_env(:gsmlg_commander, GSMLG.Commander, [])
  end

  @doc """
  Returns the Commander features enabled by configuration.
  """
  @spec configured_features(keyword()) :: [atom()]
  def configured_features(config \\ config()) do
    config
    |> Keyword.get(:features, @supported_features)
    |> normalize_features()
  end

  @doc """
  Returns true when a Commander feature is enabled.
  """
  @spec feature_enabled?(atom(), keyword()) :: boolean()
  def feature_enabled?(feature, config \\ config()) do
    feature in configured_features(config)
  end

  @doc "Returns the bounded number of simultaneous capability RPC executions."
  @spec max_in_flight_rpcs(keyword()) :: pos_integer()
  def max_in_flight_rpcs(config \\ config()) do
    Keyword.get(config, :max_in_flight_rpcs, @default_max_in_flight_rpcs)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp build_children(start_agent, start_server, config) do
    # Common children - always started
    common_children = []

    # Server-side children (control server mode)
    server_children =
      if start_server do
        [
          # Token Manager for agent authentication
          {GSMLG.Commander.TokenManager, []},
          # Session Registry for lookup
          {GSMLG.Commander.SessionRegistry, []},
          # Session Supervisor (DynamicSupervisor)
          {GSMLG.Commander.SessionSupervisor, []},
          # Manager for orchestration
          {GSMLG.Commander.Manager, []}
        ]
      else
        []
      end

    # Agent-side children (agent mode)
    agent_children =
      if start_agent do
        features = configured_features(config)
        max_in_flight_rpcs = max_in_flight_rpcs(config)

        [
          {GSMLG.Commander.CapabilityRegistry,
           initial_capabilities: builtin_capabilities(features)},
          {GSMLG.Commander.RequestDedup, []},
          {Task.Supervisor,
           name: GSMLG.Commander.RPCTaskSupervisor, max_children: max_in_flight_rpcs},
          {GSMLG.Commander.ConnectionSupervisor,
           config: config, max_in_flight_rpcs: max_in_flight_rpcs}
        ]
        |> Kernel.++(tls_children(config))
        |> Kernel.++(feature_children(features, config))
      else
        []
      end

    common_children ++ server_children ++ agent_children
  end

  defp feature_children(features, config) do
    if :pty in features do
      [
        {Registry, keys: :unique, name: GSMLG.Commander.LocalSessionRegistry},
        {GSMLG.Commander.SessionManager, []},
        {GSMLG.Commander.Terminal, [socket: GSMLG.Commander.Socket, name: config[:name]]}
      ]
    else
      []
    end
  end

  defp builtin_capabilities(features) do
    if :pty in features do
      [{GSMLG.Commander.PTYCapability.descriptor(), GSMLG.Commander.PTYCapability}]
    else
      []
    end
  end

  defp tls_children(config) do
    tls = Keyword.get(config, :tls, [])

    if tls[:enabled] == true do
      [
        {GSMLG.Commander.TLS,
         url: Keyword.fetch!(config, :platform_url),
         tls: tls,
         reload_interval_ms: tls[:reload_interval_ms] || 60_000}
      ]
    else
      []
    end
  end

  defp normalize_features(nil), do: @supported_features

  defp normalize_features(features) when is_list(features) do
    features
    |> Enum.map(&normalize_feature/1)
    |> Enum.filter(&(&1 in @supported_features))
    |> Enum.uniq()
  end

  defp normalize_feature(feature) when is_atom(feature), do: feature
  defp normalize_feature("pty"), do: :pty
  defp normalize_feature(_feature), do: nil
end
