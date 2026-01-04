# GSMLG.Commander

Distributed command execution client for the GSMLG platform. Connects to `gsmlg_admin_web` via Phoenix socket channels and provides PTY shell access for remote control.

## Features

- **Phoenix Socket Client**: Connects to admin platform using `phoenix_socket_client`
- **PTY Shell**: Provides pseudo-terminal shell for interactive remote control
- **Terminal Channel**: Bidirectional I/O streaming via WebSocket
- **HMAC Authentication**: Secure connection using signed tokens

## Architecture

```
┌─────────────────┐     WebSocket      ┌──────────────────┐
│  gsmlg_commander │ ◄──────────────► │  gsmlg_admin_web │
│                 │   Phoenix Channels │                  │
│  - PTY Shell    │                    │  - CommandPlatform│
│  - Terminal     │                    │  - SessionTracker │
│  - Great Hall   │                    │  - AgentRegistry  │
└─────────────────┘                    └──────────────────┘
```

## Configuration

Configure via `commander.toml` or environment variables:

```toml
[commander]
start = true
name = "my-commander"
platform_url = "ws://localhost:4111/commander-socket/websocket"
platform_key = "your-secret-key"
```

## Planned: Jido Agent Integration

This package includes [Jido](https://hexdocs.pm/jido) - an autonomous agent framework for Elixir. Future versions will support:

- **Autonomous Agents**: Stateful entities that can plan and execute actions
- **Dynamic Workflows**: Composable actions that agents can combine to solve problems
- **Distributed Execution**: Run thousands of lightweight agents (25KB each)
- **AI Integration**: Actions designed to support AI agent decision-making

### Resources

- [Jido Documentation](https://hexdocs.pm/jido)
- [Jido GitHub](https://github.com/agentjido/jido)
- [Agent Jido Website](https://agentjido.xyz)

## Installation

Add `gsmlg_commander` to your dependencies:

```elixir
def deps do
  [
    {:gsmlg_commander, "~> 0.1.0"}
  ]
end
```
