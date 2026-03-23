# Commander Management Module - Design Document

**Project:** gsmlg_commander within gsmlg_umbrella  
**Version:** 1.1  
**Date:** January 2026  
**Author:** Jonathan (GSMLG)

---

## Table of Contents

1. [Overview](#overview)
2. [Problem Statement](#problem-statement)
3. [Architecture](#architecture)
4. [Module Responsibilities](#module-responsibilities)
5. [Session State Machine](#session-state-machine)
6. [API Design](#api-design)
7. [Web UI Design](#web-ui-design)
8. [Configuration Schema](#configuration-schema)
9. [Telemetry Events](#telemetry-events)
10. [Security Considerations](#security-considerations)
11. [Error Handling Strategy](#error-handling-strategy)
12. [Implementation Phases](#implementation-phases)
13. [Open Questions](#open-questions)
14. [Implementation Prompts](#implementation-prompts)

---

## Overview

This design document outlines the architecture for a **Commander Management Module** within the GSMLG umbrella project. The module provides:

- Centralized lifecycle management for distributed terminal/PTY sessions
- Session orchestration and resource control
- **Web-based management UI** for operators to list, connect, and interact with commanders
- Real-time terminal access and commander tool integration

### Technology Stack & Dependencies

| Component | Technology | Notes |
|-----------|------------|-------|
| Server Framework | Phoenix + LiveView | Real-time UI |
| WebSocket | Phoenix Channels | Agent & operator connections |
| PTY Management | erlexec | Battle-tested PTY library |
| Configuration (Agent) | TOML via `gsmlg_toml` | Agent config files |
| Configuration (Server) | Elixir config | Standard Phoenix config |
| Terminal UI | xterm.js | Browser terminal emulator |
| Styling | TailwindCSS | Utility-first CSS |

The Commander Agent uses TOML configuration files parsed by `gsmlg_toml` (in-umbrella dependency).

---

## Problem Statement

Managing multiple remote commander instances requires:

- Tracking session state across distributed nodes
- Handling connection lifecycle (connect, disconnect, reconnect, timeout)
- Coordinating PTY resources with proper cleanup guarantees
- Providing visibility into active sessions for operators
- Enforcing resource limits and access controls
- **User-friendly web interface** for operators to:
  - View all available commanders at a glance
  - Connect to specific commanders
  - Access commander tools (shell, system info, file browser, etc.)
  - Monitor commander health and status

---

## Architecture

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      Commander Management Platform                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                         Web UI Layer                                    │ │
│  │                                                                         │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐   │ │
│  │  │  Dashboard  │  │ Commander   │  │  Terminal   │  │   Tools     │   │ │
│  │  │   View      │  │   List      │  │    View     │  │   Panel     │   │ │
│  │  │             │  │             │  │             │  │             │   │ │
│  │  │ - Stats     │  │ - Search    │  │ - xterm.js  │  │ - Shell     │   │ │
│  │  │ - Alerts    │  │ - Filter    │  │ - Multi-tab │  │ - Info      │   │ │
│  │  │ - Activity  │  │ - Sort      │  │ - Resize    │  │ - Files     │   │ │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘   │ │
│  │                                                                         │ │
│  │                    Phoenix LiveView + JavaScript                        │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                    │                                         │
│                                    ▼                                         │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                       Backend Services                                  │ │
│  │                                                                         │ │
│  │  ┌──────────────────┐    ┌──────────────────┐                          │ │
│  │  │ CommanderRegistry │    │ SessionSupervisor │                          │ │
│  │  │   (Registry)      │    │ (DynamicSupervisor)│                          │ │
│  │  └────────┬─────────┘    └────────┬─────────┘                          │ │
│  │           │                       │                                     │ │
│  │           ▼                       ▼                                     │ │
│  │  ┌──────────────────────────────────────────┐                          │ │
│  │  │           Session GenServer               │ (per commander)          │ │
│  │  │  ┌─────────┐  ┌─────────┐  ┌──────────┐  │                          │ │
│  │  │  │ PTY Mgr │  │ State   │  │  Tools   │  │                          │ │
│  │  │  └─────────┘  └─────────┘  └──────────┘  │                          │ │
│  │  └──────────────────────────────────────────┘                          │ │
│  │                                                                         │ │
│  │  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐     │ │
│  │  │  ResourceLimiter  │  │   AuditLogger    │  │   ToolsRegistry  │     │ │
│  │  └──────────────────┘  └──────────────────┘  └──────────────────┘     │ │
│  │                                                                         │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                    │                                         │
│                                    ▼                                         │ 
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                     Phoenix Channel Layer                               │ │
│  │  (CommanderChannel - handles WebSocket from remote agents)              │ │
│  │  (OperatorChannel - handles WebSocket from web UI)                      │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Data Flow

1. **Inbound Agent Connection**: Remote commander agent initiates WebSocket → Phoenix Channel authenticates → Session GenServer spawned under DynamicSupervisor → Registered in CommanderRegistry

2. **Web UI Interaction**: Operator opens dashboard → LiveView fetches commander list → Operator selects commander → OperatorChannel established → Tools/Terminal access enabled

3. **Command Execution**: Operator sends command via Terminal UI → OperatorChannel → Session GenServer → PTY process → Output streams back through channels to UI

4. **Tool Invocation**: Operator clicks tool button → Tool request via LiveView → Session dispatches to agent → Response rendered in UI

---

## Module Responsibilities

### CommanderRegistry

- ETS-backed process registry for O(1) session lookup
- Indexes by: session_id, user_id, agent_hostname, tags
- Provides query interface for listing/filtering active sessions
- Handles name conflicts and duplicate detection
- **Publishes PubSub events for real-time UI updates**

### SessionSupervisor

- DynamicSupervisor with `:temporary` restart strategy
- Enforces max_children limit for resource protection
- Tracks child count for capacity planning
- Implements graceful shutdown with configurable drain timeout

### Session GenServer

- Owns PTY lifecycle via erlexec
- Maintains session state: connected_at, last_activity, dimensions, metadata
- Implements idle timeout with configurable duration
- Handles reconnection within grace period (preserves PTY via tmux)
- Emits telemetry events for observability
- **Manages tool invocations and responses**

### ResourceLimiter

- Per-user session limits
- Global concurrent session ceiling
- Memory/CPU budget enforcement via cgroups (when available)
- Rate limiting on command execution

### AuditLogger

- Structured logging of all session events
- Command history with timestamps
- Authentication/authorization decisions
- Integration point for GSMLG.Telemetry

### ToolsRegistry

- Registers available tools per commander type
- Manages tool capabilities and permissions
- Routes tool requests to appropriate handlers

### TokenManager

- Generates authentication tokens for commander agents
- Manages token lifecycle (create, list, revoke, expire)
- Supports different token types (single-use, persistent, time-limited)
- Associates tokens with metadata (name, tags, allowed capabilities)
- Provides token validation for agent authentication

---

## Session State Machine

```
                    ┌─────────────┐
                    │   PENDING   │ (authentication in progress)
                    └──────┬──────┘
                           │ auth_success
                           ▼
┌─────────────┐     ┌─────────────┐
│ TERMINATED  │◄────│   ACTIVE    │◄─────────────────┐
└─────────────┘     └──────┬──────┘                  │
      ▲                    │                         │
      │                    │ disconnect              │ reconnect
      │                    ▼                         │ (within grace)
      │             ┌─────────────┐                  │
      └─────────────│ DISCONNECTED│──────────────────┘
        timeout     └─────────────┘
```

### State Definitions

| State | Description |
|-------|-------------|
| `PENDING` | WebSocket connected, awaiting authentication verification |
| `ACTIVE` | Authenticated, PTY spawned, ready for commands |
| `DISCONNECTED` | WebSocket lost, PTY preserved, awaiting reconnect |
| `TERMINATED` | Session ended, all resources released |

---

## API Design

### Internal API (GenServer calls/casts)

| Function | Type | Purpose |
|----------|------|---------|
| `start_session/2` | call | Initialize new session with config |
| `execute/2` | cast | Send input to PTY |
| `resize/3` | cast | Update terminal dimensions |
| `get_state/1` | call | Retrieve current session state |
| `terminate_session/2` | call | Graceful shutdown with reason |
| `invoke_tool/3` | call | Execute tool on commander |

### Query API (via Registry)

| Function | Purpose |
|----------|---------|
| `list_sessions/1` | Filter sessions by criteria |
| `count_by_user/1` | Session count for rate limiting |
| `find_by_hostname/1` | Lookup by agent identifier |
| `broadcast/2` | Send message to matching sessions |
| `subscribe/0` | Subscribe to commander events |

### REST API (for external integrations)

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/commanders` | GET | List active commanders |
| `/api/commanders/:id` | GET | Commander details |
| `/api/commanders/:id` | DELETE | Force terminate |
| `/api/commanders/:id/tools` | GET | List available tools |
| `/api/commanders/:id/tools/:tool` | POST | Invoke tool |

### Token Management API

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/tokens` | GET | List all tokens (with pagination) |
| `/api/tokens` | POST | Generate new token |
| `/api/tokens/:id` | GET | Token details (masked) |
| `/api/tokens/:id` | DELETE | Revoke token |
| `/api/tokens/:id/regenerate` | POST | Regenerate token value |

### WebSocket Channels

| Channel | Purpose |
|---------|---------|
| `commander:lobby` | Commander list updates, presence |
| `commander:terminal:{id}` | Terminal I/O for specific commander |
| `commander:tools:{id}` | Tool invocations and responses |

---

## Web UI Design

### UI Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Web UI Architecture                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Technology Stack:                                                           │
│  - Phoenix LiveView for reactive server-rendered UI                          │
│  - JavaScript hooks for xterm.js terminal integration                        │
│  - TailwindCSS for styling                                                   │
│  - Alpine.js for lightweight client-side interactivity                       │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                        Application Layout                               │ │
│  │  ┌──────────────────────────────────────────────────────────────────┐  │ │
│  │  │  Navigation Bar                                                   │  │ │
│  │  │  [Logo] [Dashboard] [Commanders] [Tokens] [Settings] [User Menu] │  │ │
│  │  └──────────────────────────────────────────────────────────────────┘  │ │
│  │  ┌────────────┬─────────────────────────────────────────────────────┐  │ │
│  │  │            │                                                      │  │ │
│  │  │  Sidebar   │              Main Content Area                       │  │ │
│  │  │            │                                                      │  │ │
│  │  │ - Quick    │  Renders based on current route:                     │  │ │
│  │  │   filters  │  - Dashboard (stats, recent activity)                │  │ │
│  │  │ - Favorite │  - Commander List (searchable table)                 │  │ │
│  │  │   cmds     │  - Commander Detail (info + tools + terminal)        │  │ │
│  │  │ - Tags     │  - Tokens (generate, list, manage)                   │  │ │
│  │  │            │  - Settings (preferences, account)                   │  │ │
│  │  │            │                                                      │  │ │
│  │  └────────────┴─────────────────────────────────────────────────────┘  │ │
│  │  ┌──────────────────────────────────────────────────────────────────┐  │ │
│  │  │  Status Bar: [Connected Commanders: 42] [Active PTYs: 12] [CPU]  │  │ │
│  │  └──────────────────────────────────────────────────────────────────┘  │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Page Designs

#### 1. Dashboard Page

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Dashboard                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐             │
│  │  Total Cmders   │  │  Active Now     │  │  Alerts         │             │
│  │      127        │  │      42         │  │      3          │             │
│  │  ↑ 5 today      │  │  ↓ 2 from peak  │  │  2 critical     │             │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘             │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  Recent Activity                                                      │  │
│  │  ────────────────────────────────────────────────────────────────    │  │
│  │  • web-prod-01 connected                            2 min ago         │  │
│  │  • db-master-03 shell session started by admin      5 min ago         │  │
│  │  • api-worker-12 disconnected (timeout)            15 min ago         │  │
│  │  • cache-node-05 reconnected                       22 min ago         │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  ┌──────────────────────────────┐  ┌──────────────────────────────────┐   │
│  │  Commanders by Status        │  │  Commanders by Tag               │   │
│  │  ┌────────────────────────┐  │  │  ┌────────────────────────────┐ │   │
│  │  │  ████████████░░ 85%    │  │  │  │  production    ███████ 45  │ │   │
│  │  │  Active                 │  │  │  │  staging       ████    28  │ │   │
│  │  │  ██░░░░░░░░░░░░ 10%    │  │  │  │  development   ███     22  │ │   │
│  │  │  Disconnected           │  │  │  │  monitoring    ██      15  │ │   │
│  │  │  █░░░░░░░░░░░░░  5%    │  │  │  │  database      █       12  │ │   │
│  │  │  Pending                │  │  │  │  other         █        5  │ │   │
│  │  └────────────────────────┘  │  │  └────────────────────────────┘ │   │
│  └──────────────────────────────┘  └──────────────────────────────────┘   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### 2. Token Management Page

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Agent Tokens                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Agent tokens allow commander agents to authenticate with the server.       │
│  Generate a token, then configure your agent with the token value.          │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  [+ Generate New Token]                                               │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  Name          │ Created     │ Last Used   │ Status   │ Actions      │  │
│  │  ──────────────────────────────────────────────────────────────────  │  │
│  │  prod-servers  │ Dec 15      │ 2 min ago   │ 🟢 Active │ [···]       │  │
│  │  staging-fleet │ Dec 20      │ 1 hour ago  │ 🟢 Active │ [···]       │  │
│  │  dev-local     │ Jan 02      │ Never       │ 🟡 Unused │ [···]       │  │
│  │  old-token     │ Nov 10      │ 30 days ago │ 🔴 Expired│ [···]       │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                         Generate New Token                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Token Name *                                                                │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  production-web-servers                                               │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  Description (optional)                                                      │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  Token for production web tier servers                                │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  Expiration                                                                  │
│  ○ Never expires                                                            │
│  ● Expires in: [30 days ▼]                                                  │
│  ○ Custom date: [____________]                                              │
│                                                                              │
│  Allowed Capabilities                                                        │
│  ☑ Shell (PTY access)                                                       │
│  ☑ File Browser                                                             │
│  ☑ Process Manager                                                          │
│  ☑ System Info                                                              │
│  ☐ Service Manager (requires elevated permissions)                          │
│                                                                              │
│  Auto-assign Tags                                                            │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  [production] [web-tier] [+ Add tag]                                  │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│                                        [Cancel]  [Generate Token]           │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                         Token Generated Successfully                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ⚠️  Copy this token now. You won't be able to see it again!                │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  cmdr_tk_a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8s9t0u1v2w3x4y5z6     │  │
│  │                                                           [📋 Copy]  │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  Agent Configuration Example (config.toml):                                  │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  # Commander Agent Configuration                                      │  │
│  │  [server]                                                             │  │
│  │  url = "wss://commander.example.com/agent/connect"                    │  │
│  │  token = "cmdr_tk_a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8s9t0u1v2w3x4y5z6"│
│  │                                                                       │  │
│  │  [agent]                                                              │  │
│  │  hostname = "web-prod-01"   # Optional, defaults to system hostname   │  │
│  │  heartbeat_interval = 30    # Seconds                                 │  │
│  │                                                                       │  │
│  │  [capabilities]                                                       │  │
│  │  shell = true                                                         │  │
│  │  files = true                                                         │  │
│  │  processes = true                                                     │  │
│  │  system_info = true                                                   │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│                                                      [Done]                  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### 3. Commander List Page

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Commanders                                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  🔍 Search commanders...                    [Filter ▼] [Tags ▼]      │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  ☐ │ Status │ Hostname              │ Capabilities │ Tags     │ Connected│
│  │  ──────────────────────────────────────────────────────────────────────│
│  │  ☐ │ 🟢     │ web-prod-01.acme.com  │ 🖥📁⚙📊     │ prod,web │ 2h ago  │
│  │  ☐ │ 🟢     │ web-prod-02.acme.com  │ 🖥📁⚙📊     │ prod,web │ 2h ago  │
│  │  ☐ │ 🟡     │ db-master-01.acme.com │ 🖥⚙📊       │ prod,db  │ 5m ago  │
│  │  ☐ │ 🟢     │ api-worker-01.acme.com│ 🖥📁⚙📊📋   │ prod,api │ 1h ago  │
│  │  ☐ │ 🔴     │ cache-01.acme.com     │ ⚙📊         │ prod     │ disconn │
│  │  ☐ │ 🟢     │ monitor-01.acme.com   │ 📊📋        │ monitor  │ 30m ago │
│  │  ──────────────────────────────────────────────────────────────────────│
│  │                                                                        │
│  │  Capability icons: 🖥=Shell 📁=Files ⚙=Processes 📊=Metrics 📋=Logs   │
│  │                                                                        │
│  │  Showing 1-6 of 127 commanders              [◄ Prev] [1] [2] [Next ►] │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  Selected: 0    [Connect] [Bulk Actions ▼]                                  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### 4. Commander Detail Page

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  ← Back to List          web-prod-01.acme.com                    🟢 Active  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  [Overview] [Shell] [Files] [Processes] [Logs] [Metrics]            │   │
│  │                                                                      │   │
│  │  Note: Tabs shown based on commander capabilities. Shell tab only   │   │
│  │  appears if commander supports PTY. Grayed tabs = not supported.    │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  ══════════════════════════════════════════════════════════════════════    │
│  OVERVIEW TAB:                                                               │
│  ══════════════════════════════════════════════════════════════════════    │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  Status & Connection                                                  │  │
│  │  ─────────────────────────────────────────────────────────────────   │  │
│  │                                                                       │  │
│  │  ┌─────────────┐                                                      │  │
│  │  │  🟢 ACTIVE  │  Connected 2 hours ago • Last activity 2 min ago    │  │
│  │  └─────────────┘                                                      │  │
│  │                                                                       │  │
│  │  Agent ID: agent-abc123-def456                                        │  │
│  │  IP Address: 192.168.1.50                                             │  │
│  │  Agent Version: 1.2.3                                                 │  │
│  │  Reconnects: 0                                                        │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  Host Information                                                     │  │
│  │  ─────────────────────────────────────────────────────────────────   │  │
│  │                                                                       │  │
│  │  Hostname      web-prod-01.acme.com                                   │  │
│  │  OS            Ubuntu 22.04.3 LTS (Jammy Jellyfish)                  │  │
│  │  Kernel        5.15.0-91-generic                                      │  │
│  │  Architecture  x86_64                                                 │  │
│  │  Uptime        45 days, 12 hours, 34 minutes                         │  │
│  │  Timezone      America/New_York (EST)                                 │  │
│  │                                                                       │  │
│  │  CPU           Intel Xeon E5-2680 v4 @ 2.40GHz (4 cores)             │  │
│  │  Memory        8 GB (5.2 GB used, 65%)                               │  │
│  │  Disk          100 GB (45 GB used, 45%)                              │  │
│  │                                                                       │  │
│  │  Primary IP    192.168.1.50                                           │  │
│  │  Public IP     203.0.113.50                                           │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  Capabilities                                                         │  │
│  │  ─────────────────────────────────────────────────────────────────   │  │
│  │                                                                       │  │
│  │  This commander supports the following tools:                         │  │
│  │                                                                       │  │
│  │  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐│  │
│  │  │ 🖥️ Shell     │ │ 📁 Files     │ │ ⚙️ Processes │ │ 📊 Metrics   ││  │
│  │  │ ✅ Supported │ │ ✅ Supported │ │ ✅ Supported │ │ ✅ Supported ││  │
│  │  │ [Open Shell]│ │ [Browse]     │ │ [View]       │ │ [View]       ││  │
│  │  └──────────────┘ └──────────────┘ └──────────────┘ └──────────────┘│  │
│  │                                                                       │  │
│  │  ┌──────────────┐ ┌──────────────┐                                   │  │
│  │  │ 📋 Logs      │ │ 🔧 Services  │                                   │  │
│  │  │ ✅ Supported │ │ ❌ Disabled  │                                   │  │
│  │  │ [View Logs] │ │ Not allowed  │                                   │  │
│  │  └──────────────┘ └──────────────┘                                   │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  Tags                                                                 │  │
│  │  ─────────────────────────────────────────────────────────────────   │  │
│  │  [production] [web-tier] [us-east-1] [acme-corp] [+ Add Tag]         │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  Quick Actions                                                        │  │
│  │  ─────────────────────────────────────────────────────────────────   │  │
│  │  [🖥️ Open Shell] [📊 View Metrics] [📁 Browse Files] [🔄 Refresh]   │  │
│  │  [⚠️ Disconnect] [🗑️ Remove]                                         │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### 5. Shell/Terminal Tab (only shown if commander supports PTY)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  ← Back to List          web-prod-01.acme.com                    🟢 Active  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  [Overview] [█Shell█] [Files] [Processes] [Logs] [Metrics]          │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  Terminal Sessions:  [+ New Session]                                  │  │
│  │  ┌─────────┐ ┌─────────┐                                             │  │
│  │  │ bash #1 │ │ bash #2 │                                             │  │
│  │  │    ×    │ │    ×    │                                             │  │
│  │  └─────────┘ └─────────┘                                             │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  ┌────────────────────────────────────────────────────────────────┐  │  │
│  │  │ deploy@web-prod-01:~$ ls -la                                   │  │  │
│  │  │ total 48                                                        │  │  │
│  │  │ drwxr-xr-x  6 deploy deploy 4096 Jan  6 10:00 .                │  │  │
│  │  │ drwxr-xr-x 12 root   root   4096 Dec 15 08:00 ..               │  │  │
│  │  │ -rw-r--r--  1 deploy deploy  220 Dec 15 08:00 .bash_logout     │  │  │
│  │  │ -rw-r--r--  1 deploy deploy 3771 Dec 15 08:00 .bashrc          │  │  │
│  │  │ drwxr-xr-x  3 deploy deploy 4096 Dec 20 14:30 app              │  │  │
│  │  │ drwxr-xr-x  2 deploy deploy 4096 Dec 20 14:30 logs             │  │  │
│  │  │ deploy@web-prod-01:~$ █                                         │  │  │
│  │  │                                                                 │  │  │
│  │  │                                                                 │  │  │
│  │  │                                                                 │  │  │
│  │  └────────────────────────────────────────────────────────────────┘  │  │
│  │                                                                       │  │
│  │  [Ctrl+C] [Ctrl+D] [Clear]                    80×24  |  bash  |  UTF-8│  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

Commander Without Shell Support (Shell tab disabled/grayed):
┌─────────────────────────────────────────────────────────────────────────────┐
│  ← Back to List          monitoring-agent-01                     🟢 Active  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  [Overview] [Shell] [Files] [Processes] [Logs] [Metrics]            │   │
│  │              ~~~~~~ (grayed out - not supported)                    │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  If user clicks disabled Shell tab:                                         │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                                                                       │  │
│  │                    🚫 Shell Access Not Available                      │  │
│  │                                                                       │  │
│  │    This commander does not support interactive shell access.          │  │
│  │                                                                       │  │
│  │    Possible reasons:                                                  │  │
│  │    • The agent was configured without PTY capability                  │  │
│  │    • The authentication token doesn't allow shell access              │  │
│  │    • Shell access is disabled for security reasons                    │  │
│  │                                                                       │  │
│  │    Available capabilities for this commander:                         │  │
│  │    ✅ System Info  ✅ Metrics  ✅ Logs                                │  │
│  │                                                                       │  │
│  │    Contact your administrator if you need shell access.               │  │
│  │                                                                       │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### 6. Tools Panel Designs

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              FILES TAB                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Path: /home/deploy/app                              [↑ Up] [🏠 Home]       │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  Name                    │ Size     │ Modified        │ Permissions   │  │
│  │  ──────────────────────────────────────────────────────────────────  │  │
│  │  📁 config/              │ -        │ Dec 20, 14:30   │ drwxr-xr-x   │  │
│  │  📁 lib/                 │ -        │ Dec 20, 14:30   │ drwxr-xr-x   │  │
│  │  📁 priv/                │ -        │ Dec 20, 14:30   │ drwxr-xr-x   │  │
│  │  📄 mix.exs              │ 2.1 KB   │ Dec 20, 14:30   │ -rw-r--r--   │  │
│  │  📄 mix.lock             │ 15.3 KB  │ Dec 20, 14:30   │ -rw-r--r--   │  │
│  │  📄 README.md            │ 4.2 KB   │ Dec 15, 10:00   │ -rw-r--r--   │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  Selected: mix.exs    [📥 Download] [👁 View] [✏️ Edit] [🗑 Delete]         │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                            PROCESSES TAB                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  🔍 Filter processes...                              [Refresh] [Tree View]  │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  PID    │ User   │ CPU%  │ MEM%  │ Command                           │  │
│  │  ──────────────────────────────────────────────────────────────────  │  │
│  │  1234   │ deploy │ 12.5  │ 8.2   │ beam.smp -A 16 -- -root /usr...  │  │
│  │  1456   │ deploy │ 0.5   │ 2.1   │ erl_child_setup 1024             │  │
│  │  2341   │ root   │ 0.1   │ 0.5   │ /usr/sbin/sshd -D                │  │
│  │  3421   │ root   │ 0.0   │ 0.3   │ /usr/sbin/cron -f                │  │
│  │  4521   │ deploy │ 2.3   │ 4.1   │ postgres: web_app web_app...     │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  Selected: 1234    [🔍 Details] [📊 Trace] [⏹ Stop] [☠ Kill]               │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                              METRICS TAB                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Time Range: [Last 1 hour ▼]                         [Auto-refresh: 10s]   │
│                                                                              │
│  ┌─────────────────────────────────┐  ┌─────────────────────────────────┐  │
│  │  CPU Usage                      │  │  Memory Usage                   │  │
│  │  ┌───────────────────────────┐  │  │  ┌───────────────────────────┐ │  │
│  │  │     ╱╲    ╱╲              │  │  │  │  ──────────────────────   │ │  │
│  │  │ ───╱  ╲──╱  ╲─────        │  │  │  │                     62%   │ │  │
│  │  │                    12%    │  │  │  │  Used: 5.0 GB             │ │  │
│  │  │                           │  │  │  │  Free: 3.0 GB             │ │  │
│  │  └───────────────────────────┘  │  │  └───────────────────────────┘ │  │
│  └─────────────────────────────────┘  └─────────────────────────────────┘  │
│                                                                              │
│  ┌─────────────────────────────────┐  ┌─────────────────────────────────┐  │
│  │  Network I/O                    │  │  Disk I/O                       │  │
│  │  ┌───────────────────────────┐  │  │  ┌───────────────────────────┐ │  │
│  │  │  ↓ 2.5 MB/s    ↑ 1.2 MB/s│  │  │  │  Read: 50 MB/s            │ │  │
│  │  │  ╱╲╱╲╱╲╱╲╱╲╱╲╱╲╱╲       │  │  │  │  Write: 12 MB/s           │ │  │
│  │  └───────────────────────────┘  │  │  └───────────────────────────┘ │  │
│  └─────────────────────────────────┘  └─────────────────────────────────┘  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### LiveView Components

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        LiveView Component Structure                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  lib/gsmlg_commander_web/live/                                              │
│  ├── dashboard_live.ex           # Dashboard page                           │
│  ├── commander_list_live.ex      # Commander list page                      │
│  ├── commander_show_live.ex      # Commander detail page                    │
│  ├── tokens_live.ex              # Token management page                    │
│  │                                                                           │
│  ├── components/                                                             │
│  │   ├── commander_card.ex       # Card in list view                        │
│  │   ├── commander_table.ex      # Table in list view                       │
│  │   ├── status_badge.ex         # Status indicator                         │
│  │   ├── capability_badge.ex     # Capability indicator (supported/disabled)│
│  │   ├── tag_list.ex             # Tag display/edit                         │
│  │   ├── terminal.ex             # Terminal wrapper (hooks xterm.js)        │
│  │   ├── file_browser.ex         # File browser component                   │
│  │   ├── process_list.ex         # Process list component                   │
│  │   ├── metrics_chart.ex        # Metrics visualization                    │
│  │   ├── activity_feed.ex        # Recent activity stream                   │
│  │   ├── stats_card.ex           # Statistics card                          │
│  │   ├── host_info.ex            # Host information display                 │
│  │   ├── capabilities_grid.ex    # Capabilities overview with action buttons│
│  │   │                                                                       │
│  │   └── tokens/                                                             │
│  │       ├── token_form.ex       # New token form                           │
│  │       ├── token_table.ex      # Token list table                         │
│  │       ├── token_details.ex    # Token details modal                      │
│  │       └── token_generated.ex  # Generated token display                  │
│  │                                                                           │
│  └── hooks/                                                                  │
│      ├── terminal_hook.js        # xterm.js integration                     │
│      ├── chart_hook.js           # Chart.js integration                     │
│      └── clipboard_hook.js       # Clipboard operations                     │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Commander Tools

Tools are capabilities that a commander agent can provide. Each tool's availability depends on:
1. **Agent configuration** - What the agent binary supports
2. **Token capabilities** - What the authentication token allows
3. **Server policy** - Administrative restrictions

| Tool | Description | Implementation | Capability Key |
|------|-------------|----------------|----------------|
| **Shell** | Interactive terminal access | xterm.js + PTY via WebSocket | `shell` |
| **System Info** | OS, hardware, network details | Agent collects via system calls | `system_info` |
| **File Browser** | Navigate, view, download files | Agent file operations | `files` |
| **Process Manager** | List, inspect, manage processes | Agent wraps `ps`, signals | `processes` |
| **Log Viewer** | View and tail log files | Agent file streaming | `logs` |
| **Metrics** | CPU, memory, disk, network | Agent metrics collection | `metrics` |
| **Port Scanner** | Check listening ports | Agent wraps `netstat`/`ss` | `network` |
| **Service Manager** | Start/stop/restart services | Agent wraps systemctl | `services` |

**Capability Inheritance:**
```
Token Capabilities ∩ Agent Capabilities = Available Tools for Session
```

Example: If token allows `[shell, files, processes]` but agent only supports `[shell, system_info, metrics]`, then the session only has access to `[shell]`.

### Real-time Updates

```elixir
# PubSub topics for real-time UI updates

# Commander lifecycle events
"commanders:events"           # New connections, disconnections, status changes
"commanders:{id}:status"      # Specific commander status updates

# Terminal I/O
"terminal:{session_id}:output"  # PTY output for terminal display
"terminal:{session_id}:resize"  # Terminal resize events

# Tool updates
"tools:{commander_id}:metrics"   # Live metrics streaming
"tools:{commander_id}:processes" # Process list updates
"tools:{commander_id}:files"     # File system change notifications

# User presence
"presence:commanders"            # Who's viewing what commander
```

---

## Configuration Schema

```elixir
# Proposed config structure
config :gsmlg_commander, GSMLG.Commander.Manager,
  # Session limits
  max_sessions_per_user: 5,
  max_total_sessions: 1000,
  
  # Timeouts (milliseconds)
  idle_timeout: :timer.minutes(15),
  reconnect_grace_period: :timer.minutes(2),
  auth_timeout: :timer.seconds(30),
  
  # PTY defaults
  default_shell: "/bin/bash",
  default_term: "xterm-256color",
  default_dimensions: {80, 24},
  
  # Resource limits
  max_output_buffer_bytes: 1_048_576,  # 1MB
  command_rate_limit: {100, :timer.minutes(1)},
  
  # Cleanup
  cleanup_interval: :timer.minutes(5),
  stale_session_threshold: :timer.hours(24)

# Web UI configuration
config :gsmlg_commander, GSMLG.CommanderWeb,
  # UI preferences
  default_theme: :dark,
  terminal_font_size: 14,
  terminal_font_family: "JetBrains Mono, monospace",
  
  # Pagination
  commanders_per_page: 25,
  max_terminal_sessions_per_commander: 5,
  
  # Real-time updates
  metrics_refresh_interval: :timer.seconds(10),
  process_list_refresh_interval: :timer.seconds(5),
  
  # File browser
  max_file_preview_size: 1_048_576,  # 1MB
  allowed_download_extensions: ~w(.txt .log .json .yaml .yml .toml .md),
  
  # Security
  require_2fa_for_shell: false,
  audit_all_commands: true
```

---

## Telemetry Events

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:commander, :session, :start]` | - | session_id, user_id, hostname |
| `[:commander, :session, :stop]` | duration_ms | session_id, reason |
| `[:commander, :command, :execute]` | latency_ms | session_id, command_length |
| `[:commander, :output, :flush]` | bytes | session_id |
| `[:commander, :pool, :usage]` | active, available | - |
| `[:commander, :ui, :page_view]` | - | page, user_id |
| `[:commander, :ui, :tool_invoke]` | latency_ms | tool, commander_id, user_id |

---

## Security Considerations

1. **Authentication**: Token-based auth during WebSocket handshake, validated against user service
2. **Authorization**: Per-session capability checks, operator vs agent permissions
3. **Isolation**: Each PTY runs as dedicated system user when possible
4. **Audit Trail**: All commands logged with user attribution
5. **Rate Limiting**: Command frequency caps prevent abuse
6. **Input Validation**: Command blocklist for dangerous patterns
7. **UI Security**: CSRF protection, secure cookies, CSP headers
8. **Tool Permissions**: Per-tool authorization checks

---

## Error Handling Strategy

| Failure Mode | Recovery Action |
|--------------|-----------------|
| PTY process crash | Log, notify user, terminate session |
| WebSocket disconnect | Enter DISCONNECTED state, start grace timer |
| Memory limit exceeded | Flush buffers, warn user, terminate if persistent |
| Authentication failure | Reject connection, log attempt, rate limit IP |
| Supervisor crash | DynamicSupervisor restarts, sessions lost (acceptable) |
| UI WebSocket disconnect | Auto-reconnect with exponential backoff |
| Tool timeout | Display error, allow retry |

---

## Implementation Phases

### Phase 1 - Core Infrastructure
- Registry and DynamicSupervisor setup
- Basic Session GenServer with PTY lifecycle
- Phoenix Channel integration

### Phase 2 - Basic Web UI
- Dashboard with statistics
- Commander list with search/filter
- Basic commander detail page

### Phase 3 - Terminal Integration
- xterm.js integration via LiveView hooks
- Multi-tab terminal support
- Terminal resize handling

### Phase 4 - Tools Implementation
- System info tool
- File browser tool
- Process manager tool

### Phase 5 - Advanced Features
- Metrics visualization
- Log viewer
- Service manager
- Session sharing (multiple observers)

### Phase 6 - Polish
- Dark/light theme
- Keyboard shortcuts
- Mobile responsive design
- Export/import configurations

---

## Open Questions

1. Should sessions persist across application restarts (requires external state store)?
2. What granularity for command audit logging - every keystroke or command boundaries?
3. Integration approach with existing GSMLG.Telemetry vs dedicated logging?
4. Multi-node clustering strategy for session distribution?
5. Should file browser support uploads?
6. How to handle large log files (streaming vs pagination)?

---

## Implementation Prompts

### Prompt 1: Registry and Supervisor Foundation

```
Project: gsmlg_commander within gsmlg_umbrella

Create the foundation for commander session management with these components:

1. GSMLG.Commander.SessionRegistry
   - Use Registry with :unique keys
   - Support registration with metadata: %{user_id, hostname, connected_at, tags}
   - Implement lookup functions: by_id/1, by_user/1, by_hostname/1
   - Add list_all/0 and count/0 for monitoring
   - Include via_tuple/1 helper for GenServer naming
   - Publish PubSub events on registration/deregistration for UI updates

2. GSMLG.Commander.SessionSupervisor  
   - DynamicSupervisor with :temporary restart strategy
   - max_children configurable via application env (default 1000)
   - start_session/1 that spawns Session GenServer with proper child_spec
   - terminate_session/1 for graceful shutdown
   - count_children/0 for capacity monitoring

3. Integration with existing application.ex supervisor tree

Testing requirements:
- Registry concurrent registration/lookup
- Supervisor respects max_children
- Cleanup on process termination
- PubSub events are published correctly

Follow OTP conventions. Use @moduledoc and @doc. Emit telemetry events for 
start/stop. Reference config from :gsmlg_commander application env.
```

---

### Prompt 1.5: Token Manager for Agent Authentication

```
Project: gsmlg_commander within gsmlg_umbrella

Create token management system for commander agent authentication:

1. GSMLG.Commander.TokenManager (lib/gsmlg_commander/token_manager.ex)
   
   GenServer managing agent authentication tokens:
   
   State (ETS-backed for persistence across restarts):
   - tokens table: token_id -> %Token{
       id: uuid,
       name: string,
       description: string | nil,
       token_hash: bcrypt_hash (never store plaintext),
       token_prefix: first 8 chars for identification,
       capabilities: [:shell, :files, :processes, :system_info, :logs, :metrics, :services],
       auto_tags: [string],  # Tags to assign to commanders using this token
       expires_at: DateTime | nil,
       created_at: DateTime,
       created_by: user_id,
       last_used_at: DateTime | nil,
       use_count: integer,
       revoked: boolean,
       revoked_at: DateTime | nil,
       revoked_by: user_id | nil
     }
   
   Public API:
   - generate_token(params) -> {:ok, %{token: plaintext, id: uuid}} | {:error, reason}
     params: name, description, capabilities, auto_tags, expires_in | expires_at, created_by
     Returns plaintext token ONLY on creation (format: cmdr_tk_<random_base62>)
   
   - validate_token(plaintext_token) -> {:ok, %Token{}} | {:error, :invalid | :expired | :revoked}
     Used during agent authentication
     Updates last_used_at and use_count on success
   
   - list_tokens(opts \\ []) -> [%Token{}]
     opts: created_by, active_only, include_revoked
     Returns tokens with token_hash redacted
   
   - get_token(id) -> {:ok, %Token{}} | {:error, :not_found}
     Returns token details (hash redacted)
   
   - revoke_token(id, revoked_by) -> :ok | {:error, reason}
     Marks token as revoked, disconnects any commanders using it
   
   - regenerate_token(id, regenerated_by) -> {:ok, %{token: plaintext}} | {:error, reason}
     Creates new token value, invalidates old one
   
   - delete_token(id) -> :ok | {:error, reason}
     Permanently deletes token (for cleanup of old revoked tokens)
   
   - cleanup_expired() -> {:ok, count}
     Called periodically to mark expired tokens

2. Token Format:
   - Prefix: cmdr_tk_
   - Body: 48 characters of URL-safe base62 (a-zA-Z0-9)
   - Total: 56 characters
   - Example: cmdr_tk_a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8s9T0u1V2w3X4

3. Token Storage (lib/gsmlg_commander/token_store.ex):
   - Use DETS or ETS with periodic persistence to disk
   - Store in priv/tokens.dets
   - Load on startup, periodic flush
   - Alternative: Use Ecto with database table if preferred
   
   Schema for database option:
   ```elixir
   create table(:commander_tokens) do
     add :name, :string, null: false
     add :description, :text
     add :token_hash, :string, null: false
     add :token_prefix, :string, null: false
     add :capabilities, {:array, :string}, default: []
     add :auto_tags, {:array, :string}, default: []
     add :expires_at, :utc_datetime
     add :created_by, :string, null: false
     add :last_used_at, :utc_datetime
     add :use_count, :integer, default: 0
     add :revoked, :boolean, default: false
     add :revoked_at, :utc_datetime
     add :revoked_by, :string
     timestamps()
   end
   ```

4. Integration with Session authentication:
   - Update Session.authenticate to use TokenManager.validate_token
   - Store validated token capabilities in session state
   - Apply auto_tags to session metadata
   - Enforce capability restrictions on tool requests

5. Security considerations:
   - Use Bcrypt for token hashing (Argon2id also acceptable)
   - Constant-time comparison for token validation
   - Rate limit validation attempts (via TokenRateLimiter)
   - Log all token operations for audit
   - Never log or return plaintext tokens except on generation

Testing:
- Token generation produces valid format
- Validation succeeds with correct token
- Validation fails with wrong/expired/revoked token
- Capabilities are correctly enforced
- Rate limiting prevents brute force

Emit telemetry events:
- [:commander, :token, :generated]
- [:commander, :token, :validated]
- [:commander, :token, :validation_failed]
- [:commander, :token, :revoked]
```

---

### Prompt 1.6: Token Management UI

```
Project: gsmlg_commander within gsmlg_umbrella
Depends on: Prompt 1.5 (Token Manager)

Create LiveView pages for token management:

1. GSMLG.CommanderWeb.TokensLive (lib/gsmlg_commander_web/live/tokens_live.ex)
   
   mount/3:
   - Fetch all tokens for current user (or all if admin)
   - Subscribe to token events
   
   State (assigns):
   - tokens: [%Token{}]
   - show_modal: nil | :new | :details | :revoke | :regenerate | :generated
   - selected_token: %Token{} | nil
   - generated_token: string | nil (plaintext, only shown once)
   - form: %Ecto.Changeset{} for new token form
   
   render/1:
   - Page header with description
   - "Generate New Token" button
   - Token list table:
     * Name (with prefix badge: cmdr_tk_a1B2...)
     * Created date
     * Last used (or "Never")
     * Status badge (Active/Unused/Expired/Revoked)
     * Actions menu (View, Regenerate, Revoke, Delete)
   
   handle_event "open_new_modal":
   - Set show_modal to :new
   - Initialize form changeset
   
   handle_event "generate_token", params:
   - Validate form
   - Call TokenManager.generate_token
   - On success: set generated_token, show_modal to :generated
   - On error: update form with errors
   
   handle_event "view_token", %{"id" => id}:
   - Fetch token details
   - Set show_modal to :details
   
   handle_event "revoke_token", %{"id" => id}:
   - Confirm dialog
   - Call TokenManager.revoke_token
   - Refresh list, show success flash
   
   handle_event "regenerate_token", %{"id" => id}:
   - Confirm dialog
   - Call TokenManager.regenerate_token
   - Show new token value (once)
   
   handle_event "delete_token", %{"id" => id}:
   - Confirm dialog (only for revoked tokens)
   - Call TokenManager.delete_token
   
   handle_event "close_modal":
   - Clear modal state, generated_token
   
   handle_event "copy_token":
   - Trigger JS clipboard copy via hook

2. Components:

   token_form.ex:
   - Name input (required)
   - Description textarea
   - Expiration selector (never, 30/60/90 days, custom)
   - Capabilities checkboxes
   - Auto-tags input
   
   token_generated_modal.ex:
   - Warning: "Copy now, shown only once"
   - Token display with copy button
   - Agent configuration example
   - Done button
   
   token_details_modal.ex:
   - Token info (name, description, created, last used)
   - Capabilities list
   - Auto-tags
   - Usage statistics
   - Regenerate/Revoke buttons

3. JavaScript hooks (assets/js/hooks/):
   
   clipboard_hook.js:
   - Copy text to clipboard
   - Show "Copied!" feedback
   
4. Routes update:
   live "/tokens", TokensLive, :index
   live "/tokens/new", TokensLive, :new (or use modal)

Authorization:
- All authenticated users can manage their own tokens
- Admins can view/manage all tokens
- Use current_user from socket.assigns

Styling:
- Use TailwindCSS
- Consistent with other pages
- Copy button with visual feedback
- Secure display of token (monospace, clear background)
```

---

### Prompt 2: Session GenServer Core

```
Project: gsmlg_commander within gsmlg_umbrella
Depends on: Prompt 1 (Registry and Supervisor)

Create GSMLG.Commander.Session GenServer for managing individual commander sessions:

State structure:
- id: unique session identifier (UUID)
- user_id: authenticated user
- hostname: remote agent identifier  
- status: :pending | :active | :disconnected | :terminated
- pty_pid: erlexec OS pid (nil until active)
- pty_ref: monitor reference
- channel_pid: Phoenix Channel process (for output delivery)
- dimensions: {cols, rows}
- connected_at: DateTime
- last_activity: DateTime
- metadata: map for extensibility (os, kernel, uptime, etc.)
- tools: list of available tools reported by agent
- operator_pids: list of attached operator processes

Callbacks:
- init/1: Register in SessionRegistry, set status :pending, start auth_timeout timer
- handle_call {:authenticate, token}: Validate token, spawn PTY on success, 
  transition to :active, cancel auth timer
- handle_call :get_state: Return sanitized state map
- handle_call {:invoke_tool, tool_name, params}: Dispatch tool request to agent
- handle_cast {:input, data}: Forward to PTY via :exec.send, update last_activity
- handle_cast {:resize, cols, rows}: Call :exec.setopt for PTY resize
- handle_cast {:attach_operator, pid}: Add operator to list, monitor it
- handle_cast {:detach_operator, pid}: Remove operator from list
- handle_info {:stdout, os_pid, data}: Forward to all attached operators
- handle_info {:DOWN, ref, :process, pid, reason}: Handle PTY or operator death
- handle_info {:tool_response, tool, result}: Forward tool response to operators
- handle_info :idle_timeout: Check last_activity, terminate if exceeded
- handle_info :auth_timeout: Terminate if still :pending
- terminate/2: Kill PTY, deregister, log audit event, notify operators

PTY spawning (in activate/1 private function):
- Use :exec.run with [:stdin, :stdout, :stderr, :pty, :pty_echo, :monitor]
- Set TERM environment variable from config
- Apply dimensions from state

Configuration from application env:
- idle_timeout_ms (default 15 minutes)
- auth_timeout_ms (default 30 seconds)  
- default_shell (default "/bin/bash")
- default_term (default "xterm-256color")

Use Process.flag(:trap_exit, true) for cleanup guarantees.
Emit telemetry: [:commander, :session, :start|:stop|:activate]
Publish PubSub events for status changes.
```

---

### Prompt 3: Phoenix Channel Integration

```
Project: gsmlg_commander within gsmlg_umbrella
Depends on: Prompts 1-2

Create Phoenix Channels for WebSocket communication:

1. GSMLG.CommanderWeb.AgentChannel (for remote agents)
   
   Channel topic: "agent:connect"
   
   join/3:
   - Extract auth token from params
   - Validate agent credentials
   - Call SessionSupervisor.start_session with agent config
   - On success: monitor session, store session_pid in assigns
   - On failure: {:error, %{reason: "..."}}
   
   handle_in "authenticate", payload:
   - Complete authentication handshake
   - Store agent metadata (os, capabilities, tools)
   
   handle_in "pty_output", %{"pty_id" => id, "data" => data}:
   - Forward to Session GenServer for distribution to operators
   
   handle_in "tool_response", %{"tool" => tool, "result" => result}:
   - Forward to Session GenServer
   
   handle_in "heartbeat", _:
   - Update last_seen, respond with pong

2. GSMLG.CommanderWeb.OperatorChannel (for web UI)
   
   Channel topic: "operator:terminal:{commander_id}"
   
   join/3:
   - Validate operator JWT from socket.assigns
   - Check authorization for commander
   - Attach operator to Session
   - Send current terminal state (scrollback buffer)
   
   handle_in "input", %{"data" => data}:
   - Forward to Session GenServer
   - Return :noreply
   
   handle_in "resize", %{"cols" => cols, "rows" => rows}:
   - Validate dimensions
   - Forward to Session GenServer
   
   handle_in "invoke_tool", %{"tool" => tool, "params" => params}:
   - Dispatch tool request via Session
   - Respond with request_id for async result
   
   handle_info {:terminal_output, data}:
   - push "output", %{data: Base.encode64(data)}
   
   handle_info {:tool_response, tool, result}:
   - push "tool_result", %{tool: tool, result: result}

3. GSMLG.CommanderWeb.LobbyChannel (for dashboard)
   
   Channel topic: "commander:lobby"
   
   join/3:
   - Subscribe to commander events PubSub
   - Send current commander list summary
   
   handle_info {:commander_event, event}:
   - push "commander_update", event

Socket authentication in UserSocket:
- Verify JWT token in connect/3
- Store user_id, roles in socket.assigns

Include @impl true annotations. Handle all error cases gracefully.
Push structured error messages to client on failures.
```

---

### Prompt 4: Web UI - Dashboard and List Pages

```
Project: gsmlg_commander within gsmlg_umbrella
Depends on: Prompts 1-3

Create LiveView pages for dashboard and commander listing:

1. GSMLG.CommanderWeb.DashboardLive (lib/gsmlg_commander_web/live/dashboard_live.ex)
   
   mount/3:
   - Subscribe to "commanders:events" PubSub topic
   - Fetch initial statistics from SessionRegistry
   - Fetch recent activity from AuditLog
   
   State (assigns):
   - stats: %{total: int, active: int, disconnected: int, pending: int}
   - by_tag: %{tag => count}
   - recent_activity: [activity_event]
   - alerts: [alert]
   
   render/1:
   - Stats cards row (total, active, alerts)
   - Recent activity feed
   - Charts: commanders by status, by tag
   
   handle_info {:commander_event, event}:
   - Update stats and activity feed reactively

2. GSMLG.CommanderWeb.CommanderListLive (lib/gsmlg_commander_web/live/commander_list_live.ex)
   
   mount/3:
   - Subscribe to "commanders:events"
   - Fetch initial commander list with pagination
   
   State (assigns):
   - commanders: [commander]
   - page: int
   - per_page: int
   - total: int
   - search: string
   - filters: %{status: atom, tags: [string]}
   - sort: {field, direction}
   - selected: MapSet of ids
   
   handle_event "search", %{"query" => query}:
   - Update search, refetch with filter
   
   handle_event "filter", %{"status" => status}:
   - Update filters, refetch
   
   handle_event "sort", %{"field" => field}:
   - Toggle sort direction, refetch
   
   handle_event "select", %{"id" => id}:
   - Toggle selection in MapSet
   
   handle_event "page", %{"page" => page}:
   - Update page, refetch
   
   handle_event "connect", %{"id" => id}:
   - Navigate to commander detail page

3. Components (lib/gsmlg_commander_web/live/components/)
   
   stats_card.ex:
   - attr :title, :string
   - attr :value, :integer
   - attr :trend, :string (optional, e.g., "↑ 5 today")
   - attr :color, :atom
   
   commander_row.ex:
   - attr :commander, :map
   - attr :selected, :boolean
   - Renders status badge, hostname, tags, connected time
   
   status_badge.ex:
   - attr :status, :atom
   - Renders colored badge (🟢 active, 🟡 pending, 🔴 disconnected)
   
   tag_list.ex:
   - attr :tags, :list
   - Renders clickable tag badges
   
   pagination.ex:
   - attr :page, :integer
   - attr :total_pages, :integer
   - attr :on_page_change, :string (event name)

4. Routes (lib/gsmlg_commander_web/router.ex):
   
   live "/", DashboardLive, :index
   live "/commanders", CommanderListLive, :index
   live "/commanders/:id", CommanderShowLive, :show
   live "/commanders/:id/:tab", CommanderShowLive, :show
   live "/tokens", TokensLive, :index
   live "/tokens/new", TokensLive, :new

Use TailwindCSS for styling. Make components reusable.
Implement real-time updates via PubSub subscriptions.
Add loading states and error handling.
```

---

### Prompt 5: Web UI - Commander Detail and Terminal

```
Project: gsmlg_commander within gsmlg_umbrella
Depends on: Prompts 1-4

Create LiveView for commander detail page with terminal integration:

1. GSMLG.CommanderWeb.CommanderShowLive (lib/gsmlg_commander_web/live/commander_show_live.ex)
   
   mount/3:
   - Fetch commander details from Session
   - Subscribe to commander-specific PubSub topics
   - Initialize tab state (default: :info)
   
   State (assigns):
   - commander: %{id, hostname, status, metadata, tools, ...}
   - tab: :info | :shell | :files | :processes | :logs | :metrics
   - terminals: [%{id, title, active}]
   - active_terminal: terminal_id
   - tool_results: %{tool_name => result}
   
   handle_params/3:
   - Update tab from URL params
   
   render/1:
   - Header with commander name, status, back button
   - Tab navigation
   - Tab content area (renders based on current tab)
   
   handle_event "change_tab", %{"tab" => tab}:
   - Update tab, patch URL
   
   handle_event "new_terminal":
   - Create new terminal session
   - Add to terminals list
   
   handle_event "close_terminal", %{"id" => id}:
   - Close terminal session
   - Remove from list
   
   handle_event "select_terminal", %{"id" => id}:
   - Set active_terminal

2. Terminal Component with JS Hook
   (lib/gsmlg_commander_web/live/components/terminal.ex)
   
   def render(assigns):
   - div with phx-hook="Terminal" and data attributes
   - data-terminal-id, data-commander-id
   
   (assets/js/hooks/terminal_hook.js):
   
   mounted():
   - Initialize xterm.js Terminal
   - Load FitAddon, WebLinksAddon
   - Connect to OperatorChannel via Phoenix Socket
   - Set up bidirectional data flow:
     * term.onData -> channel.push("input", {data})
     * channel.on("output") -> term.write(base64decode(data))
   - Handle resize: fitAddon.fit(), channel.push("resize", {cols, rows})
   - Set up ResizeObserver for container
   
   destroyed():
   - Dispose terminal
   - Leave channel
   
   reconnected():
   - Reconnect channel, request buffer replay

3. Tab Components
   
   info_tab.ex:
   - System information display
   - Connection details
   - Tags management
   - Quick action buttons
   
   shell_tab.ex:
   - Terminal session tabs
   - New session button
   - Terminal component for active session
   
   files_tab.ex:
   - File browser component (implement in next prompt)
   
   processes_tab.ex:
   - Process list component (implement in next prompt)
   
   metrics_tab.ex:
   - Metrics charts (implement in next prompt)

4. CSS for terminal (assets/css/terminal.css):
   - Container styling
   - Tab styling
   - xterm.js theme customization (dark/light)

5. JavaScript bundle updates (assets/js/app.js):
   - Import xterm.js and addons
   - Register Terminal hook

Ensure terminal properly resizes with container.
Handle connection errors gracefully with reconnection.
Support multiple terminal tabs per commander.
Implement copy/paste functionality.
```

---

### Prompt 6: Commander Tools - File Browser

```
Project: gsmlg_commander within gsmlg_umbrella
Depends on: Prompts 1-5

Create file browser tool for commanders:

1. Agent-side file operations (protocol messages):
   
   Tool requests (server -> agent):
   - list_directory: {path} -> {entries: [{name, type, size, mtime, permissions}]}
   - read_file: {path, offset?, limit?} -> {content, total_size}
   - write_file: {path, content} -> {ok | error}
   - delete_file: {path} -> {ok | error}
   - create_directory: {path} -> {ok | error}
   - file_info: {path} -> {size, mtime, permissions, owner, group}
   
   Security on agent:
   - Respect allowed_paths configuration
   - Never follow symlinks outside allowed paths
   - Enforce read-only mode if configured

2. GSMLG.Commander.Tools.FileBrowser (lib/gsmlg_commander/tools/file_browser.ex)
   
   Functions:
   - list_directory(session, path)
   - read_file(session, path, opts \\ [])
   - download_file(session, path) -> binary stream
   - get_file_info(session, path)
   
   Validation:
   - Sanitize paths (no .., absolute only)
   - Check file extension against allowed list for downloads
   - Enforce size limits for preview

3. FileBrowserComponent (lib/gsmlg_commander_web/live/components/file_browser.ex)
   
   State:
   - current_path: string
   - entries: [entry]
   - selected: entry | nil
   - loading: boolean
   - preview: {filename, content} | nil
   - breadcrumbs: [path_segment]
   
   Events:
   - navigate: Change directory
   - select: Select file/directory
   - download: Initiate file download
   - preview: Show file content in modal
   - refresh: Reload current directory
   - go_up: Navigate to parent directory
   - go_home: Navigate to home directory
   
   render/1:
   - Breadcrumb navigation
   - Toolbar (up, home, refresh, view toggle)
   - File/folder list or grid
   - Selected item actions
   - Preview modal

4. File preview component:
   
   - Detect file type from extension
   - Text files: syntax highlighted (use highlight.js)
   - Images: inline display
   - Binary: hex dump preview
   - Large files: truncated with "load more"

5. Download handling:
   
   Controller endpoint for downloads:
   GET /api/commanders/:id/files/download?path=...
   
   - Stream file content through Phoenix
   - Set proper Content-Disposition header
   - Verify authorization
   - Audit log download

6. LiveView integration in files_tab.ex:
   
   mount:
   - Initialize at user's home directory
   
   handle_event "navigate", %{"path" => path}:
   - Invoke list_directory tool
   - Update entries and current_path
   
   handle_event "download", %{"path" => path}:
   - Redirect to download endpoint
   
   handle_event "preview", %{"path" => path}:
   - Invoke read_file tool (with size limit)
   - Show preview modal

Style with TailwindCSS.
Add loading spinners and error states.
Implement keyboard navigation (arrow keys, enter).
```

---

### Prompt 7: Commander Tools - Process Manager and System Info

```
Project: gsmlg_commander within gsmlg_umbrella
Depends on: Prompts 1-6

Create process manager and system info tools:

1. Agent-side process operations:
   
   Tool requests:
   - list_processes: {} -> {processes: [{pid, user, cpu, mem, cmd, state}]}
   - process_info: {pid} -> {detailed process info}
   - kill_process: {pid, signal} -> {ok | error}
   - process_tree: {} -> {tree structure}
   
   System info requests:
   - system_info: {} -> {
       hostname, os, kernel, uptime,
       cpu: {model, cores, usage},
       memory: {total, used, free, cached},
       disk: [{mount, total, used, free}],
       network: [{interface, ip, rx_bytes, tx_bytes}],
       load_average: [1m, 5m, 15m]
     }

2. GSMLG.Commander.Tools.ProcessManager
   
   Functions:
   - list_processes(session, opts \\ [])
     opts: sort_by, filter_user, filter_cmd
   - get_process_info(session, pid)
   - kill_process(session, pid, signal \\ :term)
   - get_process_tree(session)
   
   Signal mapping:
   - :term -> SIGTERM (15)
   - :kill -> SIGKILL (9)
   - :hup -> SIGHUP (1)
   - :int -> SIGINT (2)

3. GSMLG.Commander.Tools.SystemInfo
   
   Functions:
   - get_system_info(session)
   - get_cpu_usage(session) -> streaming metrics
   - get_memory_usage(session)
   - get_disk_usage(session)
   - get_network_stats(session)

4. ProcessListComponent (lib/gsmlg_commander_web/live/components/process_list.ex)
   
   State:
   - processes: [process]
   - sort: {field, direction}
   - filter: string
   - selected: pid | nil
   - view_mode: :list | :tree
   - auto_refresh: boolean
   - refresh_interval: integer (ms)
   
   Events:
   - sort: Change sort field/direction
   - filter: Update filter text
   - select: Select process
   - kill: Send signal to process
   - refresh: Manual refresh
   - toggle_auto_refresh: Enable/disable auto refresh
   - toggle_view: Switch list/tree view
   
   render/1:
   - Filter input
   - Toolbar (refresh, auto-refresh toggle, view toggle)
   - Process table with sortable columns
   - Selected process actions (details, kill options)

5. SystemInfoComponent (lib/gsmlg_commander_web/live/components/system_info.ex)
   
   State:
   - info: system info map
   - loading: boolean
   
   render/1:
   - Grid of info cards:
     * System (hostname, OS, kernel, uptime)
     * CPU (model, cores, current usage)
     * Memory (used/total with progress bar)
     * Disk (per-mount usage)
     * Network (interfaces, IPs)
     * Load average

6. MetricsComponent (lib/gsmlg_commander_web/live/components/metrics_chart.ex)
   
   State:
   - time_range: atom (:hour | :day | :week)
   - metrics: %{cpu: [...], memory: [...], ...}
   - auto_refresh: boolean
   
   JS Hook (metrics_chart_hook.js):
   - Initialize Chart.js
   - Update data on push events
   - Handle time range changes
   
   render/1:
   - Time range selector
   - Grid of charts:
     * CPU usage over time
     * Memory usage over time
     * Network I/O
     * Disk I/O

7. Integration in processes_tab.ex and metrics_tab.ex:
   
   processes_tab:
   - ProcessListComponent with auto-refresh
   - Process detail modal
   
   metrics_tab:
   - SystemInfoComponent at top
   - MetricsComponent charts below

Add confirmation dialogs for destructive actions (kill process).
Implement periodic refresh via :timer.send_interval.
Handle tool timeouts gracefully.
```

---

### Prompt 8: Resource Management and Limits

```
Project: gsmlg_commander within gsmlg_umbrella
Depends on: Prompts 1-7

Create GSMLG.Commander.ResourceManager for enforcing limits:

1. GSMLG.Commander.ResourceManager GenServer
   - Tracks: sessions_by_user (ETS counter), total_sessions
   - check_limits/1 returns :ok | {:error, :user_limit} | {:error, :global_limit}
   - reserve_slot/1 increments counters (called before session start)
   - release_slot/1 decrements counters (called on session end)
   - get_usage/0 returns current statistics
   
   Configuration:
   - max_sessions_per_user (default 5)
   - max_total_sessions (default 1000)
   - max_terminals_per_commander (default 5)

2. GSMLG.Commander.OutputBuffer (integrate into Session)
   - Circular buffer for PTY output
   - max_buffer_bytes configurable (default 1MB)
   - Implements backpressure: when buffer exceeds threshold, 
     batch output at 50ms intervals instead of immediate push
   - flush/1 returns accumulated data and resets buffer
   - get_scrollback/1 returns last N lines for new operator connections
   
3. Update Session GenServer:
   - Call ResourceManager.check_limits in init before proceeding
   - Call ResourceManager.reserve_slot on successful auth
   - Call ResourceManager.release_slot in terminate
   - Integrate OutputBuffer for stdout handling
   - Add handle_info :flush_output for batched delivery

4. Rate limiting for commands:
   - Use :ex_rated or simple token bucket in Session state
   - Configurable: {max_commands, window_ms}
   - Return {:error, :rate_limited} when exceeded
   - Show rate limit warnings in UI

5. UI integration:
   - Show resource usage in dashboard
   - Display warnings when approaching limits
   - Graceful error messages when limits exceeded

Telemetry events:
- [:commander, :limits, :rejected] with reason metadata
- [:commander, :buffer, :overflow] when backpressure activates
```

---

### Prompt 9: Admin API and Observability

```
Project: gsmlg_commander within gsmlg_umbrella
Depends on: Prompts 1-8

Create admin endpoints and observability infrastructure:

1. GSMLG.CommanderWeb.API.AdminController
   
   GET /api/admin/commanders
   - List all sessions with pagination
   - Filter params: user_id, hostname, status, tags
   - Returns: [{id, user_id, hostname, status, connected_at, last_activity}]
   - Requires admin role in conn.assigns
   
   GET /api/admin/commanders/:id
   - Full session details including dimensions, metadata
   - Returns 404 if not found
   
   DELETE /api/admin/commanders/:id  
   - Force terminate session
   - Body: {"reason": "optional reason"}
   - Returns 204 on success
   
   GET /api/admin/commanders/stats
   - Aggregate statistics
   - Returns: {total_active, by_status, by_user_top_10, avg_duration}
   
   GET /api/admin/audit
   - Audit log entries with pagination
   - Filter params: user_id, commander_id, event_type, date_range

2. GSMLG.Commander.Telemetry module
   - attach_handlers/0 called from application start
   - Handler for [:commander, :session, :*] events
   - Handler for [:commander, :ui, :*] events
   - Integrate with GSMLG.Telemetry app if available
   - Metrics: session_count gauge, session_duration histogram,
     commands_total counter, output_bytes counter

3. GSMLG.Commander.AuditLog
   - log_event/2 accepts event_type and metadata
   - Events: session_start, session_end, command_executed, 
     auth_failed, limit_exceeded, admin_action, tool_invoked,
     file_downloaded, process_killed
   - Structured format: timestamp, event_type, session_id, 
     user_id, ip_address, details
   - Backend configurable: Logger, file, external service, database
   - Include command content for command_executed (configurable)
   - Retention policy: configurable days to keep

4. Router additions in router.ex:
   - Scope "/api/admin" with admin authentication plug
   - Include proper CORS and rate limiting

5. Admin UI page:
   - Audit log viewer with filters
   - System-wide statistics
   - User management (if applicable)
   - Configuration viewer

Authorization: Implement GSMLG.CommanderWeb.Plugs.RequireAdmin
that checks for admin role in JWT claims.
```

---

### Prompt 10: Reconnection and Session Persistence

```
Project: gsmlg_commander within gsmlg_umbrella
Depends on: Prompts 1-9

Implement reconnection handling for network interruptions:

1. Update Session GenServer state machine:
   
   Add fields:
   - reconnect_token: random token generated on disconnect
   - disconnect_timer_ref: reference for grace period timer
   - grace_period_ms: from config (default 2 minutes)
   - output_buffer_during_disconnect: accumulated output
   
   New transitions:
   - When agent channel dies (not explicit terminate):
     - Set status to :disconnected
     - Generate reconnect_token
     - Start disconnect_timer
     - Keep PTY alive
     - Notify attached operators
   
   handle_call {:reconnect, token, new_channel_pid}:
   - Verify token matches reconnect_token
   - Cancel disconnect_timer
   - Update channel_pid
   - Set status back to :active
   - Clear reconnect_token
   - Return buffered output since disconnect
   - Notify operators of reconnection
   
   handle_info :grace_period_expired:
   - If still :disconnected, terminate session

2. Update AgentChannel:
   
   join/3 with reconnect:
   - Check for "reconnect_token" in params
   - If present, call Session.reconnect instead of new session
   - On success, flush buffered output to agent
   
3. Update OperatorChannel and UI:
   
   - Show "Disconnected" overlay on terminal when commander disconnects
   - Show reconnection countdown timer
   - Auto-resume when commander reconnects
   - Replay buffered output to terminal

4. Update OutputBuffer:
   - When disconnected, continue buffering (up to limit)
   - get_buffered/0 returns data accumulated during disconnect
   - Handle buffer overflow gracefully (drop oldest)

5. Client guidance for agent (document):
   - Store reconnect_token from disconnect event
   - Implement exponential backoff reconnection
   - Pass reconnect_token on rejoin attempt

6. Optional tmux integration (if configured):
   - Instead of raw PTY, spawn tmux session
   - On disconnect, tmux session persists independently  
   - On reconnect, reattach to existing tmux session
   - Requires tmux installed on agent
   
   Config flag: use_tmux (default false)
   When enabled, spawn: tmux new-session -d -s {session_id}
   Attach via: tmux attach -t {session_id}

7. UI indicators:
   - Show connection status in commander list
   - Show reconnecting spinner
   - Show "Session preserved" badge during disconnect

Telemetry: [:commander, :session, :disconnect], [:commander, :session, :reconnect]
PubSub events for UI updates on status changes.
```

---

*End of Commander Management Module Design Document*
