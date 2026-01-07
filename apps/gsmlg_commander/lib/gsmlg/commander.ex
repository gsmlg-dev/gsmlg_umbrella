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

  @impl true
  def start(_type, _args) do
    config = Application.get_env(:gsmlg_commander, GSMLG.Commander, [])
    start_agent = Keyword.get(config, :start, false)
    start_server = Keyword.get(config, :server, true)

    Phoenix.SocketClient.Telemetry.attach_debug_handler()

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
  @spec socket_opts() :: keyword()
  def socket_opts do
    config = Application.get_env(:gsmlg_commander, GSMLG.Commander, [])
    url = Keyword.get(config, :platform_url)
    priv_key = Keyword.get(config, :platform_key)
    name = Keyword.get(config, :name, "commander-#{Enum.random(100_000..999_999)}")

    sign_at = :os.system_time(:seconds)

    [
      url: url,
      params: %{
        signature: :crypto.mac(:hmac, :sha256, priv_key, "#{name}/#{sign_at}") |> Base.encode16(),
        name: name,
        sign_at: sign_at
      }
    ]
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
    Keyword.get(config, :server, true)
  end

  @doc """
  Gets the current Commander configuration.
  """
  @spec config() :: keyword()
  def config do
    Application.get_env(:gsmlg_commander, GSMLG.Commander, [])
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
        [
          # Registry for PTY session lookup (local agent)
          {Registry, keys: :unique, name: GSMLG.Commander.LocalSessionRegistry},
          # Session manager for PTY sessions
          {GSMLG.Commander.SessionManager, []},
          # WebSocket connection
          {Phoenix.SocketClient, socket_opts() ++ [name: GSMLG.Commander.Socket]},
          # Legacy channels (backward compatibility)
          {GSMLG.Commander.GreatHall, []},
          {GSMLG.Commander.Office, []},
          # New PTY terminal channel
          {GSMLG.Commander.Terminal, [socket: GSMLG.Commander.Socket, name: config[:name]]},
          # Legacy resource manager (kept for compatibility)
          {GSMLG.Commander.Resource, []}
        ]
      else
        []
      end

    common_children ++ server_children ++ agent_children
  end
end
