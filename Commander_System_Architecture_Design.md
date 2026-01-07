# Commander System - Complete Architecture Design Document

**Project:** gsmlg_commander within gsmlg_umbrella  
**Version:** 1.0  
**Date:** January 2026  
**Author:** Jonathan (GSMLG)

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Core Concepts](#core-concepts)
3. [Architecture Layers](#architecture-layers)
4. [Detailed Component Design](#detailed-component-design)
5. [Protocol Design](#protocol-design)
6. [Server-Side Session Design](#server-side-session-design)
7. [Manager Design](#manager-design)
8. [Entity Relationships](#entity-relationships)
9. [Access Control Model](#access-control-model)
10. [Operational Scenarios](#operational-scenarios)
11. [Configuration Schema](#configuration-schema)

---

## Executive Summary

The Commander system provides secure, managed remote shell access through a reverse-connection architecture. Remote agents initiate outbound WebSocket connections to a central control server, enabling terminal access to machines behind firewalls without inbound port exposure.

---

## Core Concepts

### What is a Commander?

A **Commander** is a logical unit representing a controllable remote terminal session. It encompasses:

- **Agent**: The software running on a remote machine that initiates the connection
- **Session**: The server-side state managing the connection and PTY
- **Channel**: The bidirectional communication pathway

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

---

## Architecture Layers

### Layer 1: Agent (Remote Side)

The agent runs on target machines and:
- Initiates persistent WebSocket connection to control server
- Spawns and manages local PTY processes
- Forwards I/O between PTY and WebSocket
- Reports machine metadata (hostname, OS, capabilities)
- Handles reconnection with exponential backoff
- Implements heartbeat for connection health

### Layer 2: Transport (Protocol)

Defines the wire protocol between agents and server:
- Message framing and serialization
- Authentication handshake
- Command/response patterns
- Multiplexing multiple PTY sessions per connection
- Flow control signals

### Layer 3: Session (Server Side)

Server-side representation of a connected agent:
- Tracks connection state and metadata
- Routes operator commands to correct agent
- Manages PTY lifecycle requests
- Buffers output during operator disconnects
- Enforces access control policies

### Layer 4: Manager (Orchestration)

Coordinates all sessions:
- Registry for discovery and lookup
- Resource limit enforcement
- Health monitoring and cleanup
- Administrative operations
- Telemetry aggregation

### Layer 5: Operator Interface

How operators interact with commanders:
- Web UI with xterm.js
- API for programmatic access
- Multi-session management
- Session sharing capabilities

---

## Detailed Component Design

### Agent Design

```
┌─────────────────────────────────────────────────────────┐
│                    Commander Agent                       │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  ┌─────────────────┐     ┌─────────────────────────┐    │
│  │ ConnectionManager│     │     PTY Supervisor      │    │
│  │                 │     │  (multiple PTY support) │    │
│  │ - reconnection  │     │                         │    │
│  │ - heartbeat     │     │  ┌─────┐ ┌─────┐       │    │
│  │ - auth          │     │  │PTY 1│ │PTY 2│ ...   │    │
│  └────────┬────────┘     │  └─────┘ └─────┘       │    │
│           │              └───────────┬─────────────┘    │
│           │                          │                  │
│           ▼                          ▼                  │
│  ┌──────────────────────────────────────────────────┐  │
│  │              Message Router                       │  │
│  │  - demux incoming commands to correct PTY         │  │
│  │  - mux outgoing output with PTY identifier        │  │
│  └──────────────────────────────────────────────────┘  │
│                          │                              │
│                          ▼                              │
│  ┌──────────────────────────────────────────────────┐  │
│  │              WebSocket Client                     │  │
│  │  - TLS connection to control server               │  │
│  │  - binary frame transport                         │  │
│  └──────────────────────────────────────────────────┘  │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

### Agent Responsibilities

| Responsibility | Description |
|----------------|-------------|
| Connection Lifecycle | Establish, maintain, reconnect WebSocket to server |
| Authentication | Present credentials, handle token refresh |
| PTY Management | Spawn/resize/terminate local PTY processes |
| I/O Forwarding | Bidirectional data between PTY and WebSocket |
| Heartbeat | Periodic ping to detect stale connections |
| Metadata Reporting | Hostname, OS, user, capabilities, resource usage |
| Multi-PTY Support | Handle multiple concurrent terminal sessions |

### Agent Configuration

The Commander agent uses TOML configuration files, parsed by `gsmlg_toml`:

```toml
# /etc/commander/agent.toml (or ~/.config/commander/agent.toml)

[server]
url = "wss://control.example.com/agent/connect"
token = "cmdr_tk_your_token_here"

[agent]
# Optional: defaults to system hostname
hostname = "web-prod-01"
# Optional: auto-generated if not specified
id = "unique-agent-identifier"

[connection]
heartbeat_interval = 30          # seconds
reconnect_initial_delay = 1      # seconds
reconnect_max_delay = 60         # seconds
reconnect_backoff_multiplier = 2.0

[pty]
default_shell = "/bin/bash"      # defaults to $SHELL
default_term = "xterm-256color"
max_sessions = 10
idle_timeout = 3600              # seconds (1 hour)

[security]
allowed_shells = ["/bin/bash", "/bin/zsh", "/bin/sh"]
command_blocklist = ["rm -rf /", "mkfs", "dd if="]

[limits]
max_output_rate = 1048576        # bytes/sec
```

Agent loads configuration via:

```elixir
# lib/gsmlg_commander_agent/config.ex
defmodule GSMLG.CommanderAgent.Config do
  @moduledoc "Load agent configuration from TOML file"
  
  @config_paths [
    "/etc/commander/agent.toml",
    "~/.config/commander/agent.toml",
    "./commander.toml"
  ]
  
  def load(path \\ nil) do
    config_path = path || find_config()
    
    case GSMLG.TOML.parse_file(config_path) do
      {:ok, config} -> {:ok, normalize(config)}
      {:error, reason} -> {:error, {:config_error, reason}}
    end
  end
  
  defp find_config do
    Enum.find(@config_paths, &File.exists?(Path.expand(&1)))
  end
end
```

---

## Protocol Design

### Message Format

```
┌────────────────────────────────────────────────────────┐
│                    Frame Structure                      │
├────────────────────────────────────────────────────────┤
│  0       1       2       3       4       5+            │
│ ┌───────┬───────┬───────────────┬───────────────────┐ │
│ │ Type  │ Flags │   PTY ID      │     Payload       │ │
│ │ (1B)  │ (1B)  │   (2B)        │    (variable)     │ │
│ └───────┴───────┴───────────────┴───────────────────┘ │
└────────────────────────────────────────────────────────┘
```

### Message Types

| Type | Code | Direction | Payload | Description |
|------|------|-----------|---------|-------------|
| AUTH_REQUEST | 0x01 | A→S | JSON credentials | Initial authentication |
| AUTH_RESPONSE | 0x02 | S→A | JSON result | Auth success/failure |
| HEARTBEAT | 0x03 | A↔S | timestamp | Keep-alive ping/pong |
| PTY_SPAWN | 0x10 | S→A | JSON config | Request new PTY |
| PTY_SPAWNED | 0x11 | A→S | JSON result | PTY created with ID |
| PTY_INPUT | 0x12 | S→A | raw bytes | Stdin to PTY |
| PTY_OUTPUT | 0x13 | A→S | raw bytes | Stdout from PTY |
| PTY_RESIZE | 0x14 | S→A | cols(2B) + rows(2B) | Terminal resize |
| PTY_EXIT | 0x15 | A→S | exit_code(4B) | PTY process ended |
| PTY_KILL | 0x16 | S→A | signal(1B) | Terminate PTY |
| METADATA | 0x20 | A→S | JSON | Agent metadata update |
| ERROR | 0xFF | A↔S | JSON | Error notification |

### Authentication Flow

```
Agent                                    Server
  │                                        │
  │──────── WebSocket Connect ────────────►│
  │                                        │
  │◄─────── Connection Accepted ───────────│
  │                                        │
  │──────── AUTH_REQUEST ─────────────────►│
  │         {type, credentials, metadata}  │
  │                                        │
  │         [Server validates]             │
  │                                        │
  │◄─────── AUTH_RESPONSE ─────────────────│
  │         {status, agent_id, config}     │
  │                                        │
  │──────── METADATA ─────────────────────►│
  │         {hostname, os, resources}      │
  │                                        │
  │◄─────── HEARTBEAT ─────────────────────│
  │                                        │
  └─────── [Connected & Ready] ────────────┘
```

### PTY Session Flow

```
Operator        Server Session        Agent
   │                  │                  │
   │── attach ───────►│                  │
   │                  │── PTY_SPAWN ────►│
   │                  │                  │ [spawns PTY]
   │                  │◄── PTY_SPAWNED ──│
   │◄── ready ────────│                  │
   │                  │                  │
   │── input ────────►│── PTY_INPUT ────►│──► PTY stdin
   │                  │                  │
   │   PTY stdout ◄───│◄── PTY_OUTPUT ───│◄── PTY stdout
   │◄── output ───────│                  │
   │                  │                  │
   │── resize ───────►│── PTY_RESIZE ───►│ [SIGWINCH]
   │                  │                  │
   │                  │◄── PTY_EXIT ─────│ [PTY exited]
   │◄── exit ─────────│                  │
   │                  │                  │
```

---

## Server-Side Session Design

```
┌──────────────────────────────────────────────────────────────┐
│                    Commander Session                          │
├──────────────────────────────────────────────────────────────┤
│                                                               │
│  State:                                                       │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ agent_id: "agent-xyz-123"                               │ │
│  │ connection_pid: #PID<0.456.0>  (WebSocket handler)      │ │
│  │ status: :connected | :authenticating | :disconnected     │ │
│  │                                                          │ │
│  │ metadata: %{                                             │ │
│  │   hostname: "server-01.example.com",                     │ │
│  │   os: "Linux 5.15.0",                                    │ │
│  │   user: "deploy",                                        │ │
│  │   ip: "192.168.1.50",                                    │ │
│  │   capabilities: [:pty, :sftp, :port_forward],            │ │
│  │   tags: ["production", "web-tier"]                       │ │
│  │ }                                                        │ │
│  │                                                          │ │
│  │ pty_sessions: %{                                         │ │
│  │   1 => %PTYSession{                                      │ │
│  │     id: 1,                                               │ │
│  │     operator_pids: [#PID<0.789.0>],                      │ │
│  │     dimensions: {80, 24},                                │ │
│  │     output_buffer: <<...>>,                              │ │
│  │     created_at: ~U[2026-01-06 10:30:00Z],               │ │
│  │     last_activity: ~U[2026-01-06 10:35:00Z]             │ │
│  │   },                                                     │ │
│  │   2 => %PTYSession{...}                                  │ │
│  │ }                                                        │ │
│  │                                                          │ │
│  │ connected_at: ~U[2026-01-06 10:00:00Z]                  │ │
│  │ last_heartbeat: ~U[2026-01-06 10:35:30Z]                │ │
│  └─────────────────────────────────────────────────────────┘ │
│                                                               │
│  Capabilities:                                                │
│  - Route operator commands to agent PTYs                      │
│  - Multiplex multiple PTY sessions per agent                  │
│  - Buffer output during operator disconnects                  │
│  - Broadcast output to multiple observers                     │
│  - Handle agent reconnection with session preservation        │
│                                                               │
└──────────────────────────────────────────────────────────────┘
```

---

## Manager Design

```
┌────────────────────────────────────────────────────────────────┐
│                    Commander Manager                            │
├────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                   Agent Registry                          │  │
│  │  - Index by: agent_id, hostname, tags, user, status       │  │
│  │  - Fast lookup for routing and discovery                  │  │
│  │  - Supports pattern matching queries                      │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                 Session Supervisor                        │  │
│  │  - DynamicSupervisor for Session GenServers               │  │
│  │  - One Session per connected agent                        │  │
│  │  - Restart: :temporary (no auto-restart)                  │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                 Policy Enforcer                           │  │
│  │  - Authentication verification                            │  │
│  │  - Authorization (who can access which agents)            │  │
│  │  - Resource limits (max PTYs, bandwidth)                  │  │
│  │  - Rate limiting                                          │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                 Health Monitor                            │  │
│  │  - Track heartbeat freshness                              │  │
│  │  - Detect and clean stale sessions                        │  │
│  │  - Emit health metrics                                    │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                  Audit Logger                             │  │
│  │  - All agent connections/disconnections                   │  │
│  │  - PTY session lifecycle                                  │  │
│  │  - Command execution (configurable detail)                │  │
│  │  - Authorization decisions                                │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
└────────────────────────────────────────────────────────────────┘
```

---

## Entity Relationships

```
┌─────────────────────────────────────────────────────────────────┐
│                    Entity Relationship Model                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐         ┌──────────────┐                      │
│  │    User      │         │    Agent     │                      │
│  │              │         │              │                      │
│  │ - id         │         │ - id         │                      │
│  │ - email      │         │ - hostname   │                      │
│  │ - roles      │         │ - status     │                      │
│  │ - api_keys   │         │ - metadata   │                      │
│  └──────┬───────┘         └──────┬───────┘                      │
│         │                        │                               │
│         │ authorizes             │ connects as                   │
│         ▼                        ▼                               │
│  ┌──────────────────────────────────────┐                       │
│  │              Session                  │                       │
│  │                                       │                       │
│  │ - id                                  │                       │
│  │ - agent_id (FK)                       │                       │
│  │ - connection_status                   │                       │
│  │ - connected_at                        │                       │
│  └──────────────────┬───────────────────┘                       │
│                     │                                            │
│                     │ contains 0..N                              │
│                     ▼                                            │
│  ┌──────────────────────────────────────┐                       │
│  │            PTY Session                │                       │
│  │                                       │                       │
│  │ - pty_id (scoped to session)          │                       │
│  │ - dimensions                          │                       │
│  │ - created_at                          │                       │
│  │ - last_activity                       │                       │
│  └──────────────────┬───────────────────┘                       │
│                     │                                            │
│                     │ observed by 0..N                           │
│                     ▼                                            │
│  ┌──────────────────────────────────────┐                       │
│  │            Operator Attachment        │                       │
│  │                                       │                       │
│  │ - user_id (FK)                        │                       │
│  │ - role: :controller | :observer       │                       │
│  │ - attached_at                         │                       │
│  │ - channel_pid                         │                       │
│  └──────────────────────────────────────┘                       │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Access Control Model

### Roles and Permissions

| Role | Can Connect Agents | Can View Sessions | Can Attach PTY | Can Terminate | Admin API |
|------|-------------------|-------------------|----------------|---------------|-----------|
| Agent | ✓ (own) | - | - | - | - |
| Operator | - | ✓ (authorized) | ✓ (authorized) | ✓ (own PTYs) | - |
| Admin | - | ✓ (all) | ✓ (all) | ✓ (all) | ✓ |

### Authorization Rules

```elixir
# Policy structure
defmodule GSMLG.Commander.Policy do
  # User -> Agent access rules
  # Can be: tag-based, explicit list, or pattern matching
  
  @type access_rule :: 
    {:tags, [String.t()]} |           # User can access agents with these tags
    {:agents, [agent_id]} |           # Explicit agent ID list
    {:pattern, Regex.t()} |           # Hostname pattern matching
    :all                              # Unrestricted (admin)
    
  @type user_policy :: %{
    user_id: String.t(),
    access_rules: [access_rule],
    max_concurrent_ptys: pos_integer(),
    capabilities: [:attach, :observe, :terminate]
  }
end
```

---

## Operational Scenarios

### Scenario 1: Agent Connects

```
1. Agent initiates WebSocket to wss://control.example.com/agent/connect
2. Server accepts connection, spawns AgentSocket handler
3. Agent sends AUTH_REQUEST with token and metadata
4. Server validates token against auth service
5. Server spawns Session GenServer, registers in AgentRegistry
6. Server sends AUTH_RESPONSE with session config
7. Agent enters ready state, begins heartbeat
8. Session emits [:commander, :agent, :connected] telemetry
```

### Scenario 2: Operator Opens Terminal

```
1. Operator authenticates via web UI (JWT)
2. Operator selects agent from dashboard (queries AgentRegistry)
3. Browser connects WebSocket to /operator/terminal
4. Server validates JWT, checks authorization against Policy
5. Server looks up Session for requested agent
6. Server sends PTY_SPAWN to agent via Session
7. Agent spawns PTY, responds PTY_SPAWNED with pty_id
8. Session creates PTYSession entry, attaches operator
9. Browser initializes xterm.js, begins I/O
```

### Scenario 3: Agent Disconnects Unexpectedly

```
1. WebSocket connection lost (network issue)
2. AgentSocket handler terminates
3. Session receives {:DOWN, ...} for connection_pid
4. Session transitions to :disconnected status
5. PTY sessions preserved (output buffering continues)
6. Session starts reconnect_grace_timer (default 2 min)
7. Attached operators notified of disconnection
8. If agent reconnects within grace period:
   - Re-associate connection_pid
   - Resume PTY sessions with buffered output
9. If grace period expires:
   - Terminate all PTY sessions
   - Notify operators of session end
   - Clean up Session
```

### Scenario 4: Session Sharing

```
1. Operator A has active PTY session on agent X
2. Operator B requests to observe same session
3. Server checks B's authorization for agent X
4. Server adds B as observer to PTYSession (role: :observer)
5. B receives current terminal state (scrollback buffer)
6. Future output broadcasts to both A and B
7. Only A (controller) can send input
8. B can request control transfer (if policy allows)
```

---

## Configuration Schema

```elixir
# config/config.exs

config :gsmlg_commander,
  # Server configuration
  server: [
    # Agent WebSocket endpoint
    agent_endpoint: "/agent/connect",
    # Operator WebSocket endpoint  
    operator_endpoint: "/operator/terminal",
    
    # Connection settings
    heartbeat_interval_ms: 30_000,
    heartbeat_timeout_ms: 90_000,
    reconnect_grace_period_ms: 120_000,
    
    # Limits
    max_agents: 10_000,
    max_ptys_per_agent: 10,
    max_observers_per_pty: 5,
    max_output_buffer_bytes: 1_048_576
  ],
  
  # Authentication
  auth: [
    # Agent auth
    agent_auth_type: :token,  # :token | :certificate | :oauth
    agent_token_secret: {:system, "COMMANDER_AGENT_SECRET"},
    
    # Operator auth
    operator_auth_type: :jwt,
    jwt_secret: {:system, "COMMANDER_JWT_SECRET"}
  ],
  
  # Policy engine
  policy: [
    # Default policy for users without explicit rules
    default_access: :none,  # :none | :tagged | :all
    
    # Tag-based access (user metadata -> agent tags)
    enable_tag_matching: true
  ],
  
  # Telemetry
  telemetry: [
    # Enable telemetry events
    enabled: true,
    
    # Integration with GSMLG.Telemetry app
    forward_to_gsmlg_telemetry: true
  ],
  
  # Audit logging
  audit: [
    # Enable audit logging
    enabled: true,
    
    # Log command content (security consideration)
    log_command_content: false,
    
    # Backend: :logger | :file | :external
    backend: :logger
  ]
```

---

*End of Commander System Architecture Design Document*
