# Product Requirements Document (PRD)

## GSMLG.Umbrella Platform

**Version:** 1.0
**Last Updated:** January 2026
**Status:** Active Development

---

## 1. Executive Summary

GSMLG.Umbrella is a comprehensive, multi-purpose Elixir umbrella application designed to provide a unified platform for web services, administrative tools, distributed command execution, and various utility services. The platform combines modern web technologies with robust distributed systems capabilities, offering both public-facing web applications and powerful backend infrastructure.

### 1.1 Vision

To create a versatile, self-hosted platform that serves as a personal digital workspace, combining content management, utility tools, distributed computing capabilities, and modern web services in a cohesive, maintainable architecture.

### 1.2 Key Value Propositions

- **Unified Architecture**: Single codebase managing multiple interconnected applications
- **Self-Hosted Control**: Full ownership of data and infrastructure
- **Distributed Computing**: Command platform for orchestrating remote operations
- **Developer-Friendly**: Modern Elixir/Phoenix stack with comprehensive tooling
- **Extensible Design**: Modular umbrella structure enabling easy feature additions

---

## 2. Product Overview

### 2.1 System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     GSMLG.Umbrella Platform                     │
├─────────────────────────────────────────────────────────────────┤
│  Web Applications                                               │
│  ┌──────────────────┐  ┌──────────────────┐                    │
│  │   gsmlg_web      │  │  gsmlg_admin_web │                    │
│  │   (Port 4110)    │  │   (Port 4111)    │                    │
│  │   Public Site    │  │   Admin Panel    │                    │
│  └────────┬─────────┘  └────────┬─────────┘                    │
│           │                      │                              │
├───────────┼──────────────────────┼──────────────────────────────┤
│  Core Services                   │                              │
│  ┌──────────────────┐  ┌────────┴─────────┐                    │
│  │      gsmlg       │  │  gsmlg_commander │                    │
│  │  Business Logic  │  │ Distributed Cmds │                    │
│  │  Database Models │  │  Agent Registry  │                    │
│  └──────────────────┘  └──────────────────┘                    │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│  Infrastructure Libraries                                       │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐  │
│  │gsmlg_config│ │gsmlg_mnesia│ │ gsmlg_aws  │ │  gsmlg_pki │  │
│  └────────────┘ └────────────┘ └────────────┘ └────────────┘  │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐  │
│  │gsmlg_teleme│ │gsmlg_logger│ │gsmlg_webpus│ │gsmlg_compon│  │
│  └────────────┘ └────────────┘ └────────────┘ └────────────┘  │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│  Data Layer                                                     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │  PostgreSQL  │  │    Mnesia    │  │   CouchDB    │          │
│  │  Primary DB  │  │ Distributed  │  │  Documents   │          │
│  └──────────────┘  └──────────────┘  └──────────────┘          │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 Application Portfolio

| Application | Port | Purpose |
|-------------|------|---------|
| `gsmlg_web` | 4110 | Public-facing website with blog, toolbox, and user features |
| `gsmlg_admin_web` | 4111 | Administrative dashboard for content and system management |
| `gsmlg_commander` | - | Distributed command execution platform |
| `gsmlg` | - | Core business logic, database models, and services |

---

## 3. Functional Requirements

### 3.1 Public Web Application (gsmlg_web)

#### 3.1.1 Blog System

**Requirements:**
- Create, edit, and publish blog posts with Markdown support
- Tag-based categorization and organization
- RSS feed generation for content syndication
- SEO-optimized URLs and metadata
- Comment system with moderation capabilities

**User Stories:**
- As a content creator, I want to write and publish blog posts with rich formatting
- As a reader, I want to browse posts by tags and subscribe via RSS
- As an administrator, I want to moderate comments and manage content

#### 3.1.2 Toolbox Utilities

**IP Geolocation Tool:**
- Lookup geographic location from IP addresses
- Display country, region, city, and ISP information
- Support both IPv4 and IPv6 addresses
- API endpoint for programmatic access

**WHOIS Lookup:**
- Query domain registration information
- Display registrar, creation date, expiration date
- Show nameserver configuration
- Support for various TLDs

**MAC Address Tools:**
- Vendor lookup from MAC address prefix
- MAC address format validation and conversion
- OUI database integration

**SVG Utilities:**
- SVG preview and validation
- Format conversion capabilities
- Optimization tools

**DNS Tools:**
- DNS record lookup (A, AAAA, MX, TXT, etc.)
- Reverse DNS queries
- DNS propagation checking

#### 3.1.3 Chess Game

**Requirements:**
- Real-time multiplayer chess via WebSockets
- Game state persistence
- Move validation and legal move highlighting
- Game history and replay functionality
- ELO rating system (optional)

**Technical Implementation:**
- Phoenix Channels for real-time communication
- Mnesia for distributed game state
- React-based interactive chessboard UI

#### 3.1.4 User Authentication

**Supported Methods:**
- Email/password authentication with secure hashing
- GitHub OAuth integration
- Magic link (passwordless) authentication
- Two-factor authentication (TOTP)
- JWT tokens via Guardian

**Security Requirements:**
- Password strength validation
- Rate limiting on authentication attempts
- Secure session management
- CSRF protection

#### 3.1.5 Web Push Notifications

**Requirements:**
- VAPID key management
- Subscription management per user
- Push notification delivery
- Notification preferences

### 3.2 Administrative Application (gsmlg_admin_web)

#### 3.2.1 Dashboard

**Requirements:**
- System health overview
- User statistics and activity
- Content metrics
- Resource utilization monitoring

#### 3.2.2 Content Management

**Requirements:**
- Blog post management (CRUD operations)
- Media library management
- Tag and category administration
- Draft and scheduling features

#### 3.2.3 User Management

**Requirements:**
- User listing with search and filtering
- Role and permission management
- Account status control (active/suspended)
- User activity audit logs

#### 3.2.4 System Configuration

**Requirements:**
- Application settings management
- Feature flag controls
- Integration configuration (OAuth, AWS, etc.)
- Backup and maintenance tools

### 3.3 Command Platform (gsmlg_commander)

#### 3.3.1 Agent Management

**Requirements:**
- Agent registration and discovery
- Heartbeat monitoring
- Agent metadata and capabilities tracking
- Secure WebSocket communication

**Data Model:**
```elixir
%Agent{
  id: uuid,
  name: string,
  hostname: string,
  ip_address: string,
  capabilities: list,
  status: :online | :offline | :busy,
  last_seen: datetime,
  metadata: map
}
```

#### 3.3.2 Command Execution

**Requirements:**
- Remote command dispatch to agents
- Command queuing and prioritization
- Execution status tracking
- Result collection and storage
- Timeout handling

#### 3.3.3 Security

**Requirements:**
- Platform key authentication
- TLS encrypted communication
- Command authorization and validation
- Audit logging of all commands

### 3.4 AWS Integration

#### 3.4.1 Route53 Management

**Requirements:**
- DNS zone listing and management
- Record set operations (create, update, delete)
- Health check configuration
- Failover routing support

#### 3.4.2 DynamoDB Access

**Requirements:**
- Table operations
- Item CRUD operations
- Query and scan capabilities
- Backup management

#### 3.4.3 S3 Operations

**Requirements:**
- Bucket listing and management
- Object upload/download
- Presigned URL generation
- Lifecycle policy management

### 3.5 PKI Management

**Requirements:**
- Certificate Authority (CA) creation
- Certificate signing requests (CSR) handling
- Certificate issuance and revocation
- Certificate chain validation
- CRL (Certificate Revocation List) generation

---

## 4. Non-Functional Requirements

### 4.1 Performance

| Metric | Requirement |
|--------|-------------|
| Page Load Time | < 2 seconds (95th percentile) |
| API Response Time | < 200ms (95th percentile) |
| WebSocket Latency | < 100ms |
| Concurrent Users | Support 1000+ simultaneous users |
| Database Query Time | < 50ms for common queries |

### 4.2 Reliability

- **Uptime Target:** 99.9% availability
- **Recovery Time Objective (RTO):** < 1 hour
- **Recovery Point Objective (RPO):** < 15 minutes
- **Graceful Degradation:** System continues with reduced functionality during partial outages

### 4.3 Security

**Authentication:**
- bcrypt password hashing with configurable cost factor
- JWT tokens with configurable expiration
- Secure session management with HttpOnly cookies

**Data Protection:**
- TLS 1.3 for all external communications
- Encryption at rest for sensitive data
- SQL injection prevention via parameterized queries
- XSS protection via content security policies

**Access Control:**
- Role-based access control (RBAC)
- Principle of least privilege
- API rate limiting

### 4.4 Scalability

**Horizontal Scaling:**
- Stateless web application design
- Distributed session storage via Mnesia
- Database connection pooling

**Vertical Scaling:**
- BEAM VM efficient resource utilization
- Configurable worker pool sizes
- Memory-efficient data structures

### 4.5 Observability

**Logging:**
- Structured JSON logging
- Configurable log levels
- Log aggregation support (CloudWatch)

**Metrics:**
- Request/response metrics
- Database performance metrics
- VM and system metrics
- Custom business metrics

**Tracing:**
- Distributed trace correlation
- Span tracking for operations
- Performance profiling

### 4.6 Maintainability

- **Code Coverage Target:** > 80%
- **Documentation:** Comprehensive API documentation
- **Modularity:** Clear separation of concerns via umbrella structure
- **Dependency Management:** Regular security updates

---

## 5. Technical Specifications

### 5.1 Technology Stack

**Backend:**
| Component | Technology | Version |
|-----------|------------|---------|
| Language | Elixir | 1.17+ |
| Framework | Phoenix | 1.7+ |
| ORM | Ecto | 3.x |
| Real-time | Phoenix Channels | - |
| Auth | Guardian | 2.x |

**Frontend:**
| Component | Technology | Version |
|-----------|------------|---------|
| UI Framework | Phoenix LiveView | 1.0+ |
| Components | React | 18+ |
| Styling | Tailwind CSS | 3.x |
| Build Tool | Bun | Latest |

**Data Storage:**
| Purpose | Technology |
|---------|------------|
| Primary Database | PostgreSQL 16 |
| Distributed State | Mnesia |
| Document Store | CouchDB (optional) |

**Infrastructure:**
| Component | Technology |
|-----------|------------|
| Containerization | Docker |
| Dev Environment | Nix/devenv |
| Binary Builds | Burrito |
| CI/CD | GitHub Actions |

### 5.2 Database Schema

**Core Entities:**

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│    users     │     │    posts     │     │    tags      │
├──────────────┤     ├──────────────┤     ├──────────────┤
│ id           │────<│ user_id      │     │ id           │
│ email        │     │ id           │>────│ name         │
│ password_hash│     │ title        │     │ slug         │
│ username     │     │ body         │     └──────────────┘
│ role         │     │ published_at │            │
│ 2fa_enabled  │     │ tags         │────────────┘
└──────────────┘     └──────────────┘
        │
        │            ┌──────────────┐     ┌──────────────┐
        │            │  oauth_users │     │push_subscript│
        └───────────>│ provider     │     ├──────────────┤
                     │ provider_id  │     │ user_id      │
                     │ user_id      │     │ endpoint     │
                     └──────────────┘     │ keys         │
                                          └──────────────┘
```

**Mnesia Tables:**
- `agent_registry` - Commander agent tracking
- `game_state` - Chess game persistence
- `session_cache` - Distributed sessions

### 5.3 API Specifications

**REST API Endpoints:**

```
Authentication:
  POST   /api/auth/login          - User login
  POST   /api/auth/register       - User registration
  POST   /api/auth/logout         - User logout
  POST   /api/auth/refresh        - Token refresh

Blog:
  GET    /api/posts               - List posts
  GET    /api/posts/:id           - Get post
  POST   /api/posts               - Create post (admin)
  PUT    /api/posts/:id           - Update post (admin)
  DELETE /api/posts/:id           - Delete post (admin)

Toolbox:
  GET    /api/tools/ip/:ip        - IP geolocation
  GET    /api/tools/whois/:domain - WHOIS lookup
  GET    /api/tools/mac/:mac      - MAC vendor lookup
  GET    /api/tools/dns/:domain   - DNS lookup
```

**WebSocket Channels:**

```
Chess:
  chess:lobby     - Game matchmaking
  chess:game:*    - Individual game channels

Commander:
  commander:agent - Agent communication
  commander:admin - Admin monitoring
```

### 5.4 Configuration Management

**Environment-Specific TOML Files:**
- `gsmlg.dev.toml` - Development settings
- `gsmlg.prod.toml` - Production settings
- `gsmlg.test.toml` - Test settings

**Configuration Sections:**
```toml
[gsmlg]
mnesia_dir = "/var/lib/gsmlg/mnesia"

[logger]
log_level = "info"

[database]
username = "gsmlg"
password = "***"
socket_dir = "/run/postgresql"  # Unix socket
database = "gsmlg_prod"
pool_size = 20

[web]
url = "https://gsmlg.org"
port = 4110
secret_key_base = "***"

[admin_web]
url = "https://admin.gsmlg.org"
port = 4111

[commander]
start = true
name = "commander-prod"
platform_url = "wss://admin.gsmlg.org/commander-socket/websocket"
platform_key = "***"

[oauth.github]
client_id = "***"
client_secret = "***"

[web_push]
subject = "mailto:admin@gsmlg.org"
public_key = "***"
private_key = "***"
```

---

## 6. Deployment Requirements

### 6.1 Deployment Options

**Docker Deployment:**
```yaml
services:
  app:
    image: gsmlg-umbrella:latest
    ports:
      - "4110:4110"
      - "4111:4111"
    environment:
      - PHX_HOST=gsmlg.org
      - DATABASE_URL=postgres://...
    volumes:
      - ./config:/app/config
```

**Standalone Binary:**
- Burrito-packaged single executable
- No runtime dependencies
- Cross-platform support (Linux, macOS)

**Traditional Release:**
- Mix release with runtime configuration
- Systemd service integration
- Hot code upgrades supported

### 6.2 Infrastructure Requirements

**Minimum Production:**
- 2 CPU cores
- 4 GB RAM
- 50 GB SSD storage
- PostgreSQL 14+

**Recommended Production:**
- 4+ CPU cores
- 8+ GB RAM
- 100+ GB SSD storage
- PostgreSQL 16 with replication

### 6.3 Network Requirements

| Port | Service | Protocol |
|------|---------|----------|
| 4110 | Web Application | HTTP/HTTPS |
| 4111 | Admin Application | HTTP/HTTPS |
| 4369 | EPMD (Erlang) | TCP |
| 5432 | PostgreSQL | TCP |
| 5984 | CouchDB (optional) | HTTP |

---

## 7. Development Roadmap

### Phase 1: Foundation (Current)
- [x] Core umbrella structure
- [x] PostgreSQL integration with Unix socket support
- [x] User authentication (email, OAuth, magic links)
- [x] Basic blog functionality
- [x] Toolbox utilities
- [x] Admin dashboard structure
- [x] Telemetry and logging system

### Phase 2: Enhancement
- [ ] Complete 2FA implementation
- [ ] Advanced blog features (scheduling, SEO)
- [ ] Chess game improvements (rankings, tournaments)
- [ ] Commander platform stabilization
- [ ] Full AWS integration testing

### Phase 3: Scale
- [ ] Performance optimization
- [ ] Horizontal scaling documentation
- [ ] CDN integration for static assets
- [ ] Advanced caching strategies
- [ ] Load testing and benchmarks

### Phase 4: Enterprise
- [ ] Multi-tenancy support
- [ ] Advanced RBAC
- [ ] Audit logging enhancements
- [ ] Compliance features (GDPR tools)
- [ ] API versioning

---

## 8. Success Metrics

### 8.1 Technical KPIs

| Metric | Target | Measurement |
|--------|--------|-------------|
| Uptime | 99.9% | Monitoring tools |
| P95 Response Time | < 200ms | APM metrics |
| Error Rate | < 0.1% | Log analysis |
| Test Coverage | > 80% | CI reports |

### 8.2 User Engagement

| Metric | Target | Measurement |
|--------|--------|-------------|
| Daily Active Users | Track trend | Analytics |
| Session Duration | > 3 minutes | Analytics |
| Tool Usage | Track popularity | Application logs |
| Blog Engagement | Page views, shares | Analytics |

---

## 9. Risks and Mitigations

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| Database failure | High | Low | Regular backups, replication |
| Security breach | High | Medium | Security audits, penetration testing |
| Scalability limits | Medium | Medium | Load testing, architecture review |
| Dependency vulnerabilities | Medium | Medium | Regular updates, Dependabot |
| Data loss | High | Low | Backup verification, disaster recovery |

---

## 10. Appendices

### A. Glossary

| Term | Definition |
|------|------------|
| Umbrella Application | Elixir project structure containing multiple applications |
| LiveView | Phoenix framework for real-time server-rendered UIs |
| Guardian | JWT authentication library for Elixir |
| Mnesia | Distributed database built into Erlang/OTP |
| BEAM | Erlang virtual machine running Elixir code |
| Burrito | Tool for creating standalone Elixir executables |

### B. Related Documents

- CLAUDE.md - Development guidelines and commands
- README.md - Project overview and quick start
- CHANGELOG.md - Version history
- devenv.nix - Development environment configuration

### C. Contact

- **Repository:** https://github.com/gsmlg-dev/gsmlg_umbrella
- **Issues:** GitHub Issues
- **Maintainer:** GSMLG Team

---

*This document is a living specification and will be updated as the product evolves.*
