# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

GSMLG.Umbrella is a multi-purpose Elixir umbrella application providing web services, APIs, and administrative tools. The system includes:
- **Main web application** (`gsmlg_web`): Public-facing site with blog, toolbox utilities, and user features
- **Admin interface** (`gsmlg_admin_web`): Administrative dashboard for content management and system monitoring
- **Command platform** (`gsmlg_commander`): Distributed command execution system
- **Core services** (`gsmlg`): Database models, business logic, and background services

## Architecture

### Umbrella Structure
- **apps/gsmlg**: Core business logic, database models (Ecto), and background services
- **apps/gsmlg_web**: Public Phoenix web application (port 4110)
- **apps/gsmlg_admin_web**: Admin Phoenix web application (port 4111)  
- **apps/gsmlg_commander**: Standalone command execution service
- **apps/gsmlg_component**: Shared React components and frontend assets
- **Multiple utility libraries**: TOML parsing, PKI, CouchDB client, Web Push, etc.

### Key Technologies
- **Backend**: Elixir/Phoenix with Ecto for database access
- **Frontend**: LiveView + React components via Phoenix.React
- **Database**: MariaDB for primary data, Mnesia for distributed state, CouchDB for document storage
- **Authentication**: Guardian JWT with GitHub OAuth integration
- **Build**: Nix-based development environment + Burrito for standalone binaries
- **Container**: Docker with multi-stage builds

### Core Services
- **Whisper AI**: Speech-to-text processing using OpenAI Whisper models
- **AWS Integration**: Route53, DynamoDB, S3 management interfaces
- **Web Push**: Push notification system
- **Chess**: Multiplayer chess game with WebSocket channels
- **Toolbox**: IP geolocation, WHOIS lookup, SVG utilities, MAC address tools

## Development Setup

### Prerequisites
- Nix package manager for development environment
- MariaDB database server
- Node.js 20+ and Bun for frontend assets

### Environment Setup
```bash
# Enter development shell
nix develop

# Install dependencies for all apps
mix setup

# Create and migrate database
mix ecto.create && mix ecto.migrate
```

### Running Applications

**Development mode:**
```bash
# Start all applications (ports 4110, 4111)
mix phx.server

# Or start individual applications:
cd apps/gsmlg_web && mix phx.server
```

**Production build:**
```bash
# Build standalone binary
MIX_ENV=prod BURRITO_TARGET=linux_amd64 mix release gsmlg_umbrella_standalone

# Build Docker image
docker build -t gsmlg-umbrella .
```

### Testing

```bash
# Run all tests
mix test

# Run tests for specific app
cd apps/gsmlg && mix test
cd apps/gsmlg_web && mix test

# Run specific test file
mix test test/gsmlg_web/controllers/blog_controller_test.exs

# Run tests with coverage
mix test --cover
```

### Database Operations

```bash
# Create/migrate database
mix ecto.create
mix ecto.migrate

# Rollback migration
mix ecto.rollback

# Seed database
mix run apps/gsmlg/priv/repo/seeds.exs

# Reset database
mix ecto.reset
```

### Frontend Development

```bash
# Install JavaScript dependencies
cd apps/gsmlg_web && npm install
cd apps/gsmlg_admin_web && npm install

# Build assets
mix assets.deploy

# Watch for changes (auto-started with phx.server)
mix tailwind gsmlg_web --watch
mix bun gsmlg_web --watch
```

### Key Configuration

**Environment Variables:**
- `MARIADB_HOST`: Database host (default: mariadb-server.gsmlg.net)
- `MARIADB_USER`: Database user (default: gsmlg_dev)
- `MARIADB_PASS`: Database password (default: gsmlg_dev)
- `WEB_PORT`: Public web port (default: 4110)
- `ADMIN_PORT`: Admin web port (default: 4111)

**Important Ports:**
- 4110: Main web application
- 4111: Admin interface  
- 4112: Test web server
- 4113: Test admin server
- 4369: Erlang distribution (EPMD)

### Code Structure

**Controllers:** Follow Phoenix conventions in `lib/gsmlg_web/controllers/` and `lib/gsmlg_admin_web/controllers/`

**LiveView:** Modern live components in `lib/gsmlg_web/live/` and admin-specific views

**GraphQL:** Absinthe schema in `lib/gsmlg_web/schema/` with types for content, chess, and node management

**Channels:** Real-time communication via WebSockets for chess games and node management

**Database:** Ecto schemas in `lib/gsmlg/` with migrations in `priv/repo/migrations/`

### Common Development Tasks

**Adding new routes:** Edit the router files in respective web applications

**Database changes:** Create migrations with `mix ecto.gen.migration`, update schema files, run `mix ecto.migrate`

**Frontend components:** Use the shared component system in `apps/gsmlg_component/assets/component/`

**Authentication:** Guardian JWT tokens with session management via Phoenix.SessionProcess

**Background services:** Add to supervision tree in `lib/gsmlg/application.ex`

### Deployment

**Docker deployment:**
```bash
# Build production image
docker build -f Dockerfile -t gsmlg-umbrella .

# Run with environment variables
docker run -p 4110:4110 -p 4111:4111 -e "PHX_HOST=yourdomain.com" gsmlg-umbrella
```

**Binary release:**
```bash
# Build for target platform
MIX_ENV=prod mix release gsmlg_umbrella

# Run release
_build/prod/rel/gsmlg_umbrella/bin/gsmlg_umbrella start
```